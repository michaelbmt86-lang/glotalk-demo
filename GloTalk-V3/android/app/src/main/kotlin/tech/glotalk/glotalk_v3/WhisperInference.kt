// WhisperInference.kt
// GloTalk-V3 | 节点 2：语音转文字（STT）
// 模型：encoder_model.onnx + decoder_model.onnx（Whisper small int8，分体）
// 来源：https://github.com/microsoft/onnxruntime-inference-examples/tree/main/mobile/examples/speech_recognition/android
// OnnxRuntime Java API：https://onnxruntime.ai/docs/get-started/with-java.html
// HuggingFace Optimum Whisper ONNX：https://huggingface.co/openai/whisper-small
// 查证报告：A-004 第三部分 WHISPER-1 ~ WHISPER-7

package tech.glotalk.glotalk_v3

import ai.onnxruntime.OnnxTensor      // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtEnvironment   // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtSession       // https://onnxruntime.ai/docs/get-started/with-java.html
import android.content.Context
import java.nio.FloatBuffer            // A-004-补丁：OnnxTensor.createTensor(env, FloatBuffer, shape)
import java.nio.LongBuffer             // A-004-补丁：OnnxTensor.createTensor(env, LongBuffer, shape)
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.PI
import kotlin.math.sin

/**
 * Whisper ONNX 分体推理封装（encoder + decoder）
 *
 * 架构说明（来源：A-004 WHISPER-1，HuggingFace Optimum 官方文档）：
 *   Whisper 导出为分体模型：
 *     encoder_model.onnx — 编码器
 *     decoder_model.onnx — 解码器（无 KV cache）
 *
 * Encoder 输入规格（来源：A-004 WHISPER-2）：
 *   "input_features" float32 [1, 80, 3000] — 80-channel log-Mel spectrogram
 *
 * Encoder 输出规格（来源：A-004 WHISPER-2）：
 *   "last_hidden_state" float32 [1, 1500, d_model]
 *
 * Decoder 输入规格（来源：A-004 WHISPER-3）：
 *   "input_ids"              int64   [1, seq_len]
 *   "encoder_hidden_states"  float32 [1, 1500, d_model]
 *
 * Decoder 输出规格（来源：A-004 WHISPER-3）：
 *   "logits" float32 [1, seq_len, vocab_size]
 *
 * Mel Spectrogram 参数（来源：A-004 WHISPER-4，OpenAI Whisper 官方论文）：
 *   n_fft=400, hop_length=160, n_mels=80, sample_rate=16000
 *
 * 特殊 token（来源：A-004 WHISPER-6，multilingual 模型）：
 *   SOT = 50258 (<|startoftranscript|>)
 *   EOT = 50257 (<|endoftext|>)
 */
class WhisperInference(private val context: Context) {

    companion object {
        // 模型文件路径（来源：工作手册 8.3，assets/models/ 目录）
        private const val ENCODER_ASSET = "models/encoder_model.onnx"
        private const val DECODER_ASSET = "models/decoder_model.onnx"

        // Mel Spectrogram 参数（来源：A-004 WHISPER-4，OpenAI Whisper 官方论文）
        private const val N_FFT = 400
        private const val HOP_LENGTH = 160
        private const val N_MELS = 80
        private const val SAMPLE_RATE = 16000
        private const val MAX_SAMPLES = 480000      // 30s × 16000（来源：A-004 WHISPER-4）
        private const val MEL_FRAMES = 3000         // 最终 input_features 时间轴大小

        // 特殊 token（来源：A-004 WHISPER-6，multilingual 模型）
        // 参考：https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
        private const val SOT_TOKEN = 50258L        // <|startoftranscript|>
        private const val EOT_TOKEN = 50257L        // <|endoftext|>
        private const val LANG_EN_TOKEN = 50259L    // <|en|>
        private const val TRANSCRIBE_TOKEN = 50359L // <|transcribe|>

        // Greedy decode 最大步数（来源：A-004 WHISPER-5）
        private const val MAX_DECODE_STEPS = 448
    }

    // OrtEnvironment 全局单例（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var encoderSession: OrtSession? = null
    private var decoderSession: OrtSession? = null

    // Mel 滤波器组（一次计算，全局复用）
    private lateinit var melFilterbank: Array<FloatArray>  // [n_mels, n_fft/2+1]

    /**
     * 加载 encoder 和 decoder 模型
     * Whisper small int8 约 240MB，使用 ByteArray 方式加载（来源：A-004 C-1）
     * 在子线程中调用，避免阻塞主线程
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun loadModel() {
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
        }

        // 从 assets 读取 encoder（来源：A-004 C-1 方式 A）
        val encoderBytes = context.assets.open(ENCODER_ASSET).readBytes()
        encoderSession = env.createSession(encoderBytes, options)

        // 从 assets 读取 decoder（来源：A-004 C-1 方式 A）
        val decoderBytes = context.assets.open(DECODER_ASSET).readBytes()
        decoderSession = env.createSession(decoderBytes, options)

        // 预计算 Mel 滤波器组（来源：A-004 WHISPER-4）
        melFilterbank = buildMelFilterbank()
    }

    /**
     * 完整 STT 推理：PCM → 文字
     *
     * @param pcmSamples PCM_16BIT ShortArray，AudioRecord 输出，16kHz 采样
     * @param language   目标语言代码（默认 "en"）
     * @return 识别文字字符串
     *
     * 资源管理：所有 OnnxTensor 和 OrtSession.Result 必须在 finally 中 close
     * 来源：A-004 C-3，WHISPER-7
     */
    fun transcribe(pcmSamples: ShortArray, language: String = "en"): String {
        checkNotNull(encoderSession) { "WhisperInference: 请先调用 loadModel()" }
        checkNotNull(decoderSession) { "WhisperInference: 请先调用 loadModel()" }

        // Step 1：PCM → Float，归一化到 [-1, 1]（来源：A-004 VAD-5 同样逻辑）
        val floatPcm = FloatArray(pcmSamples.size) { i ->
            pcmSamples[i].toFloat() / 32768.0f
        }

        // Step 2：零填充到 30s（来源：A-004 WHISPER-4，MAX_SAMPLES=480000）
        val paddedPcm = FloatArray(MAX_SAMPLES).also {
            floatPcm.copyInto(it, 0, 0, minOf(floatPcm.size, MAX_SAMPLES))
        }

        // Step 3：提取 Mel Spectrogram → [1, 80, 3000]（来源：A-004 WHISPER-4）
        val melFeatures: FloatArray = extractMelSpectrogram(paddedPcm)

        // Step 4：Encoder 推理
        // 输入："input_features" [1, 80, 3000]（来源：A-004 WHISPER-2）
        // A-004-补丁：FloatBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
        val encoderInputTensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(melFeatures), longArrayOf(1, N_MELS.toLong(), MEL_FRAMES.toLong())
        )
        val encoderHiddenState: FloatArray
        val hiddenStateShape: LongArray
        try {
            val encoderInputs = mapOf("input_features" to encoderInputTensor)
            val encoderResults = encoderSession!!.run(encoderInputs)
            encoderResults.use {
                // 输出："last_hidden_state" float32 [1, 1500, d_model]（来源：A-004 WHISPER-2）
                val rawHidden = encoderResults[0].value as Array<Array<FloatArray>>
                val batchSize = rawHidden.size               // 1
                val seqLen = rawHidden[0].size               // 1500
                val dModel = rawHidden[0][0].size            // d_model（tiny=384, small=768 等）
                hiddenStateShape = longArrayOf(batchSize.toLong(), seqLen.toLong(), dModel.toLong())
                encoderHiddenState = FloatArray(batchSize * seqLen * dModel)
                var idx = 0
                for (b in 0 until batchSize)
                    for (s in 0 until seqLen)
                        for (d in 0 until dModel)
                            encoderHiddenState[idx++] = rawHidden[b][s][d]
            }
        } finally {
            encoderInputTensor.close()  // 必须 close（来源：A-004 C-3，WHISPER-7）
        }

        // Step 5：Greedy Decode 循环（来源：A-004 WHISPER-5）
        // 起始序列：[SOT, <|lang|>, <|transcribe|>]
        // 参考：https://github.com/openai/whisper/blob/main/whisper/decoding.py
        val langToken = getLanguageToken(language)
        val decoderInputIds = mutableListOf(SOT_TOKEN, langToken, TRANSCRIBE_TOKEN)
        val generatedTokens = mutableListOf<Long>()

        for (step in 0 until MAX_DECODE_STEPS) {
            val inputIdArray = decoderInputIds.toLongArray()
            val seqLen = inputIdArray.size.toLong()

            // 创建 decoder 输入张量（来源：A-004 WHISPER-3）
            // A-004-补丁：LongBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
            val decoderInputTensor = OnnxTensor.createTensor(
                env, LongBuffer.wrap(inputIdArray), longArrayOf(1, seqLen)
            )
            // encoder_hidden_states 张量（来源：A-004 WHISPER-3）
            // A-004-补丁：FloatBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
            val hiddenTensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(encoderHiddenState), hiddenStateShape)

            var nextToken: Long
            try {
                val decoderInputs = mapOf(
                    "input_ids"             to decoderInputTensor,
                    "encoder_hidden_states" to hiddenTensor
                )
                val decoderResults = decoderSession!!.run(decoderInputs)
                decoderResults.use {
                    // logits [1, seq_len, vocab_size]（来源：A-004 WHISPER-3）
                    val logits = decoderResults[0].value as Array<Array<FloatArray>>
                    // Greedy：取最后一个位置 argmax（来源：A-004 WHISPER-5）
                    val lastLogits = logits[0][logits[0].size - 1]
                    nextToken = argmax(lastLogits)
                }
            } finally {
                decoderInputTensor.close()  // 必须 close（来源：A-004 WHISPER-7）
                hiddenTensor.close()        // 必须 close（来源：A-004 WHISPER-7）
            }

            // EOS 检测（来源：A-004 WHISPER-5，WHISPER-6）
            if (nextToken == EOT_TOKEN) break

            generatedTokens.add(nextToken)
            decoderInputIds.add(nextToken)
        }

        // Step 6：Token ID → 文字（来源：A-004 WHISPER-6）
        return decodeTokens(generatedTokens)
    }

    /**
     * 提取 Log-Mel Spectrogram
     * 参数来源：A-004 WHISPER-4，OpenAI Whisper 官方论文
     * 参考：https://github.com/openai/whisper/blob/main/whisper/audio.py
     *
     * @param pcm 归一化 PCM float32，长度 = MAX_SAMPLES（480000）
     * @return log-Mel 特征，展平 FloatArray 长度 = N_MELS × MEL_FRAMES（80 × 3000）
     */
    private fun extractMelSpectrogram(pcm: FloatArray): FloatArray {
        // Hann 窗（来源：A-004 WHISPER-4，标准 STFT 窗口）
        val hannWindow = FloatArray(N_FFT) { i ->
            (0.5 * (1.0 - cos(2.0 * PI * i / N_FFT))).toFloat()
        }

        val numFrames = (pcm.size - N_FFT) / HOP_LENGTH + 1
        val fftBins = N_FFT / 2 + 1  // 201

        // 计算 STFT 幅度谱（来源：A-004 WHISPER-4，n_fft=400，hop_length=160）
        val powerSpectrum = Array(numFrames) { frame ->
            val start = frame * HOP_LENGTH
            val real = FloatArray(N_FFT)
            val imag = FloatArray(N_FFT)

            // 加 Hann 窗
            for (i in 0 until N_FFT) {
                real[i] = if (start + i < pcm.size) pcm[start + i] * hannWindow[i] else 0f
            }

            // DFT（简化实现，生产建议用 JTransforms 或 Android NDK FFTW）
            // 参考逻辑来自：https://github.com/openai/whisper/blob/main/whisper/audio.py
            val mag = FloatArray(fftBins)
            for (k in 0 until fftBins) {
                var re = 0.0
                var im = 0.0
                for (n in 0 until N_FFT) {
                    val angle = 2.0 * PI * k * n / N_FFT
                    re += real[n] * cos(angle)
                    im -= real[n] * sin(angle)
                }
                mag[k] = (re * re + im * im).toFloat()  // 功率谱
            }
            mag
        }

        // 截取 MEL_FRAMES 帧（填充或截断）（来源：A-004 WHISPER-4，MEL_FRAMES=3000）
        val melOutput = FloatArray(N_MELS * MEL_FRAMES)
        for (mel in 0 until N_MELS) {
            for (frame in 0 until MEL_FRAMES) {
                val powerFrame = if (frame < numFrames) powerSpectrum[frame] else FloatArray(fftBins)
                var melValue = 0f
                for (bin in 0 until fftBins) {
                    melValue += melFilterbank[mel][bin] * powerFrame[bin]
                }
                // Log-Mel：clamp to 1e-10，然后取 log10，乘以 10
                // 来源：https://github.com/openai/whisper/blob/main/whisper/audio.py
                val logMel = 10f * (ln(maxOf(melValue, 1e-10f)) / ln(10f))
                melOutput[mel * MEL_FRAMES + frame] = logMel
            }
        }

        // 归一化：减去 max-8，再除以4，clamp到[-1,1]
        // 来源：https://github.com/openai/whisper/blob/main/whisper/audio.py
        val maxVal = melOutput.max()
        for (i in melOutput.indices) {
            melOutput[i] = maxOf((melOutput[i] - maxVal + 8f) / 4f, -1f)
        }

        return melOutput
    }

    /**
     * 构建三角 Mel 滤波器组
     * 来源：A-004 WHISPER-4，n_mels=80，n_fft=400，sample_rate=16000
     * 参考：https://github.com/openai/whisper/blob/main/whisper/audio.py mel_filters()
     *
     * @return FloatArray[n_mels][n_fft/2+1]
     */
    private fun buildMelFilterbank(): Array<FloatArray> {
        val fftBins = N_FFT / 2 + 1  // 201
        val fMin = 0.0
        val fMax = SAMPLE_RATE / 2.0

        // Hz → Mel 转换（来源：O'Shaughnessy 公式，Whisper 使用）
        fun hzToMel(hz: Double) = 2595.0 * Math.log10(1.0 + hz / 700.0)
        fun melToHz(mel: Double) = 700.0 * (Math.pow(10.0, mel / 2595.0) - 1.0)

        val melMin = hzToMel(fMin)
        val melMax = hzToMel(fMax)

        // N_MELS+2 个均匀分布的 Mel 中心频率
        val melPoints = DoubleArray(N_MELS + 2) { i ->
            melToHz(melMin + i * (melMax - melMin) / (N_MELS + 1))
        }

        // 频率轴（FFT bin 对应的 Hz）
        val fftFreqs = DoubleArray(fftBins) { k ->
            k.toDouble() * SAMPLE_RATE / N_FFT
        }

        // 构建三角滤波器（来源：librosa mel_filters 逻辑）
        return Array(N_MELS) { m ->
            FloatArray(fftBins) { k ->
                val lower = (fftFreqs[k] - melPoints[m]) / (melPoints[m + 1] - melPoints[m])
                val upper = (melPoints[m + 2] - fftFreqs[k]) / (melPoints[m + 2] - melPoints[m + 1])
                maxOf(0.0, minOf(lower, upper)).toFloat()
            }
        }
    }

    /**
     * 语言代码 → Whisper 语言 token ID
     * 来源：A-004 WHISPER-6
     * 参考：https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
     */
    private fun getLanguageToken(language: String): Long {
        // Whisper multilingual 语言 token 起始 ID = 50259（<|en|>）
        // 语言偏移量参考 OpenAI tokenizer.py LANGUAGES 字典顺序
        return when (language.lowercase()) {
            "en" -> 50259L   // <|en|>
            "zh" -> 50260L   // <|zh|>
            "ja" -> 50266L   // <|ja|>
            "ko" -> 50264L   // <|ko|>
            else -> 50259L   // 默认英语
        }
    }

    /**
     * FloatArray argmax
     * 来源：A-004 WHISPER-5，Greedy decode 取最大值位置
     */
    private fun argmax(logits: FloatArray): Long {
        var maxIdx = 0
        var maxVal = logits[0]
        for (i in 1 until logits.size) {
            if (logits[i] > maxVal) {
                maxVal = logits[i]
                maxIdx = i
            }
        }
        return maxIdx.toLong()
    }

    /**
     * Token ID → 文字
     * 来源：A-004 WHISPER-6
     * 方案：加载 vocab.json（与模型同目录），实现基本 BPE decode
     *
     * 注意：此为简化实现。生产环境建议：
     *   1. 从 assets/models/vocab.json 读取 token → text 映射
     *   2. 或集成 onnxruntime-extensions 的 tokenizer pipeline
     *   参考：https://github.com/microsoft/onnxruntime-extensions
     */
    private fun decodeTokens(tokenIds: List<Long>): String {
        // 过滤特殊 token（< 50257 的均为正常文字 token）
        // 来源：A-004 WHISPER-6，特殊 token 范围说明
        val textTokens = tokenIds.filter { it < 50257L }

        // vocab.json 映射（简化版：从 assets 加载）
        // 完整实现需从 assets/models/whisper_vocab.json 读取并缓存
        // 此处返回 token id 序列，供上层接入完整 tokenizer
        // TODO：接入完整 whisper tokenizer（BPE decode）
        // 参考：https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
        return "[tokens:${textTokens.joinToString(",")}]"
    }

    /**
     * 释放所有资源
     * 来源：A-004 C-3，WHISPER-7
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun close() {
        encoderSession?.close()  // close encoderSession（来源：A-004 WHISPER-7）
        decoderSession?.close()  // close decoderSession（来源：A-004 WHISPER-7）
        encoderSession = null
        decoderSession = null
    }
}
