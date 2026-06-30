// PipelineOrchestrator.kt
// GloTalk-V3 — 四节点胶水层
// 职责：串联 VAD → STT → NMT，管理缓冲积累和线程调度
// 来源依据：查证报告 A-006，智能体 B 依据报告编写，不含任何猜测
//
// 路径：GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/PipelineOrchestrator.kt

package tech.glotalk.glotalk_v3

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// 来源：A-006 第六章 6.4 VAD 状态机状态枚举
private enum class VadState {
    IDLE,           // 未检测到语音，不积累
    SPEECH,         // 检测到语音（prob >= 0.5），积累帧到 speechAccumulator
    SILENCE_END     // prob < 0.35 且 triggered，开始计数静音帧
}

class PipelineOrchestrator(
    private val context: Context,
    private var sttEventSink: EventChannel.EventSink?,
    private var nmtEventSink: EventChannel.EventSink?
) {

    companion object {
        private const val TAG = "PipelineOrchestrator"

        // 来源：A-006 第一章 1.4 — Silero VAD 官方，16kHz 固定 512-sample 窗口
        private const val VAD_FRAME_SIZE = 512

        // 来源：A-006 第一章 1.5 — VADIterator 官方双门限迟滞
        private const val VAD_POSITIVE_THRESHOLD = 0.5f   // 进入语音状态
        private const val VAD_NEGATIVE_THRESHOLD = 0.35f  // 退出语音状态（0.5 - 0.15）

        // 来源：A-006 第二章 2.3 — min_silence_duration_ms = 1500ms × 16000 / 1000
        private const val MIN_SILENCE_SAMPLES = 24000     // 1.5 秒静音触发 STT

        // 来源：A-006 第二章 2.2 — 实时对话场景硬上限 5 秒
        private const val MAX_SPEECH_SAMPLES = 80000      // 5 秒，超过强制触发 STT
    }

    // 来源：A-006 第四章 4.3 — 单线程 Executor，保证 VAD LSTM 状态串行安全
    // 来源：Android Developers https://developer.android.com/develop/background-work/background-tasks/asynchronous/java-threads
    private var inferenceExecutor: ExecutorService? = null

    // 来源：A-006 第四章 4.2 — UI/EventSink 推送必须在主线程
    private val mainHandler = Handler(Looper.getMainLooper())

    // 推理节点实例（由 init() 初始化）
    private var sileroVAD: SileroVAD? = null
    private var whisperInference: WhisperInference? = null
    private var opusMTInference: OpusMTInference? = null

    // 语言参数（STT 需要）
    private var srcLang: String = "zh"
    private var tgtLang: String = "en"

    // ─── 缓冲区 ───────────────────────────────────────────────────────────────

    // 来源：A-006 第六章 6.2 F2 — VAD 512-short 窗口积累池
    private val vadAccumulator = ArrayList<Short>(VAD_FRAME_SIZE * 2)

    // 来源：A-006 第六章 6.2 F4 — 语音段积累池
    private val speechAccumulator = ArrayList<Short>(MAX_SPEECH_SAMPLES)

    // ─── VAD 状态机 ───────────────────────────────────────────────────────────

    // 来源：A-006 第六章 6.4 — 状态机状态变量
    @Volatile private var vadState: VadState = VadState.IDLE
    @Volatile private var silenceSampleCount: Int = 0

    // ─── 公开接口 ─────────────────────────────────────────────────────────────

    /**
     * 初始化四节点推理模型并启动推理线程。
     * 在 MainActivity.initModels() 中调用。
     *
     * 来源：A-006 第六章 6.3 — inferenceExecutor 在 initModels() 时创建
     * 来源：A-006 第五章 5.4 — Kotlin 层用 context.filesDir 自管模型路径
     */
    fun init(srcLang: String, tgtLang: String) {
        this.srcLang = srcLang
        this.tgtLang = tgtLang

        // 来源：A-006 第四章 4.1 — 单线程 Executor，VAD LSTM 状态非线程安全
        inferenceExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "inference-pipeline")
        }

        // 来源：A-006 第五章 5.4 — 模型文件路径：context.filesDir（不是 app_flutter）
        val filesDir = context.filesDir.absolutePath

        inferenceExecutor?.submit {
            try {
                // 节点 1：VAD
                // 来源：SileroVAD.kt（已锁死），A-006 Q1 接口确认
                val vadModelPath = "$filesDir/silero_vad.onnx"
                sileroVAD = SileroVAD(vadModelPath)
                sileroVAD?.loadModel()
                Log.d(TAG, "VAD 模型加载完成：$vadModelPath")

                // 节点 2：STT
                // 来源：WhisperInference.kt（已锁死），A-006 Q2 接口确认
                val encoderPath = "$filesDir/whisper_encoder_int8.onnx"
                val decoderPath = "$filesDir/whisper_decoder_int8.onnx"
                whisperInference = WhisperInference(encoderPath, decoderPath)
                whisperInference?.loadModel()
                Log.d(TAG, "Whisper 模型加载完成")

                // 节点 3：NMT
                // 来源：OpusMTInference.kt（已锁死），A-006 Q3 接口确认
                val opusEncoderPath = "$filesDir/opus_encoder_int8.onnx"
                val opusDecoderPath = "$filesDir/opus_decoder_int8.onnx"
                val sourceSpmPath  = "$filesDir/source.spm"
                val targetSpmPath  = "$filesDir/target.spm"
                opusMTInference = OpusMTInference(
                    context,
                    opusEncoderPath,
                    opusDecoderPath,
                    sourceSpmPath,
                    targetSpmPath
                )
                opusMTInference?.loadModel()
                Log.d(TAG, "Opus-MT 模型加载完成")

                Log.d(TAG, "四节点初始化全部完成，流水线就绪")

            } catch (e: Exception) {
                Log.e(TAG, "模型初始化失败：${e.message}", e)
            }
        }
    }

    /**
     * 接收来自 AudioService 的 PCM ByteArray，启动流水线处理。
     * 在 MainActivity 的 AudioService 回调中调用。
     *
     * 来源：A-006 第六章 6.5 — AudioService onAudioData 回调改为调用此方法
     * 来源：A-006 第四章 4.2 — PCM 采集在 AudioService 后台线程，此处 submit 到 inferenceExecutor
     */
    fun onPcmData(byteArray: ByteArray) {
        // inferenceExecutor 串行排队执行，不会并发，保证 VAD LSTM 状态安全
        // 来源：A-006 第四章 4.4 — inferenceExecutor 必须是单线程，不可并发
        inferenceExecutor?.submit {
            processPcmChunk(byteArray)
        }
    }

    /**
     * 停止流水线，释放资源。
     * 在 MainActivity.stopRecording() 和 onDestroy() 中调用。
     *
     * 来源：A-006 第六章 6.3 — Executor 生命周期管理
     */
    fun stop() {
        // 来源：A-006 第六章 6.2 F8 — 仅 stop() 时才 resetState，不在帧间调用
        sileroVAD?.resetState()

        // 重置状态机
        vadState = VadState.IDLE
        silenceSampleCount = 0
        vadAccumulator.clear()
        speechAccumulator.clear()

        // 来源：A-006 第六章 6.3 — stopRecording() 时 shutdown，onDestroy() 时 shutdownNow()
        // 来源：风险评估 B-006c — shutdown() 仅停止接受新任务，不等待已提交任务完成。
        // 若推理线程仍在跑 Whisper/NMT，destroy() 同时 close() OrtSession 会导致
        // native 层 SIGSEGV crash（场景：来电打断、快速停止重启）。
        // awaitTermination(3s) 等待当前推理任务跑完再返回，消除竞态。
        // Whisper small int8 推理正常 < 2s，3s 上限足够。
        // 来源：java.util.concurrent.ExecutorService 官方文档
        inferenceExecutor?.shutdown()
        inferenceExecutor?.awaitTermination(3, TimeUnit.SECONDS)
        inferenceExecutor = null

        Log.d(TAG, "流水线已停止")
    }

    /**
     * 强制关闭（onDestroy 调用）。
     * 来源：A-006 第六章 6.3 — onDestroy() 时 shutdownNow()
     */
    fun destroy() {
        inferenceExecutor?.shutdownNow()
        inferenceExecutor = null
        sileroVAD?.close()
        whisperInference?.close()
        opusMTInference?.close()
        Log.d(TAG, "流水线已销毁")
    }

    /**
     * 更新 EventSink 引用（EventChannel onListen/onCancel 时由 MainActivity 调用）。
     */
    fun updateSinks(
        stt: EventChannel.EventSink?,
        nmt: EventChannel.EventSink?
    ) {
        sttEventSink = stt
        nmtEventSink = nmt
    }

    // ─── 内部流水线核心 ───────────────────────────────────────────────────────

    /**
     * 处理一块 PCM ByteArray：
     * 1. ByteArray → ShortArray 还原
     * 2. 追加到 vadAccumulator
     * 3. 每积累 512 个 short → 送入 VAD
     * 4. VAD 状态机驱动 speechAccumulator 积累和 STT/NMT 触发
     *
     * 必须在 inferenceExecutor 线程中运行（单线程串行）
     * 来源：A-006 第六章 6.2 F1~F7
     */
    private fun processPcmChunk(byteArray: ByteArray) {
        // ── F1：ByteArray → ShortArray 还原 ──────────────────────────────────
        // 来源：A-006 第一章 1.3 — Little-Endian PCM_16BIT，低字节在前
        // 来源：Android AudioFormat.ENCODING_PCM_16BIT 官方文档
        val shorts = ShortArray(byteArray.size / 2) { i ->
            val lo = byteArray[i * 2].toInt() and 0xFF
            val hi = byteArray[i * 2 + 1].toInt()
            (lo or (hi shl 8)).toShort()
        }

        // 追加到 VAD 积累池
        for (s in shorts) {
            vadAccumulator.add(s)
        }

        // ── F2：VAD 512-short 窗口切割 ────────────────────────────────────────
        // 来源：A-006 第一章 1.4 — 16kHz 固定 512-sample 窗口（官方硬性要求）
        while (vadAccumulator.size >= VAD_FRAME_SIZE) {
            val frame = ShortArray(VAD_FRAME_SIZE) { i -> vadAccumulator[i] }
            repeat(VAD_FRAME_SIZE) { vadAccumulator.removeAt(0) }

            // ── F3：VAD 推理 + 迟滞状态机 ─────────────────────────────────────
            // 来源：A-006 第一章 1.5 — VADIterator 双门限迟滞
            val vad = sileroVAD ?: continue
            val prob = vad.isSpeech(frame)

            when (vadState) {

                VadState.IDLE -> {
                    if (prob >= VAD_POSITIVE_THRESHOLD) {
                        // 来源：A-006 6.4 — prob >= 0.5，进入语音状态
                        vadState = VadState.SPEECH
                        silenceSampleCount = 0
                        // 把触发帧也加入 speechAccumulator
                        for (s in frame) speechAccumulator.add(s)
                        Log.d(TAG, "VAD: IDLE → SPEECH（prob=${"%.3f".format(prob)}）")
                    }
                    // prob < 0.5 且 IDLE：继续等待，不积累
                }

                VadState.SPEECH -> {
                    if (prob >= VAD_NEGATIVE_THRESHOLD) {
                        // 来源：A-006 6.4 — prob >= 0.35，继续积累
                        for (s in frame) speechAccumulator.add(s)

                        // ── F4：硬上限检查 ─────────────────────────────────────
                        // 来源：A-006 第二章 2.2 — 超过 80000 samples 强制触发
                        if (speechAccumulator.size >= MAX_SPEECH_SAMPLES) {
                            Log.d(TAG, "VAD: 语音段达到上限（${MAX_SPEECH_SAMPLES} samples），强制触发 STT")
                            triggerSttAndNmt()
                            vadState = VadState.IDLE
                        }
                    } else {
                        // prob < 0.35，进入静音候选状态
                        vadState = VadState.SILENCE_END
                        silenceSampleCount = VAD_FRAME_SIZE  // 当前帧已是静音
                        Log.d(TAG, "VAD: SPEECH → SILENCE_END（prob=${"%.3f".format(prob)}）")
                    }
                }

                VadState.SILENCE_END -> {
                    if (prob >= VAD_NEGATIVE_THRESHOLD) {
                        // 来源：A-006 6.4 — prob >= 0.35，迟滞保护，回到 SPEECH
                        vadState = VadState.SPEECH
                        silenceSampleCount = 0
                        for (s in frame) speechAccumulator.add(s)
                        Log.d(TAG, "VAD: SILENCE_END → SPEECH（迟滞保护，prob=${"%.3f".format(prob)}）")
                    } else {
                        // 继续静音
                        silenceSampleCount += VAD_FRAME_SIZE

                        // 来源：A-006b 补充查证 — 官方 VADIterator 在 SILENCE_END 阶段
                        // 每一静音帧仍追加到语音段，直到超时触发 STT。
                        // 这样语音段末尾自然包含约 1.5 秒的静音 padding，
                        // 防止 STT 截断末尾音节。
                        // 来源：https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/utils_vad.py
                        for (s in frame) speechAccumulator.add(s)

                        // ── F5：静音超时触发 STT ───────────────────────────────
                        // 来源：A-006 第二章 2.3 — MIN_SILENCE_SAMPLES = 24000（1.5秒）
                        if (silenceSampleCount >= MIN_SILENCE_SAMPLES) {
                            if (speechAccumulator.isNotEmpty()) {
                                Log.d(TAG, "VAD: 静音超时（${silenceSampleCount} samples），触发 STT")
                                triggerSttAndNmt()
                            }
                            vadState = VadState.IDLE
                            silenceSampleCount = 0
                        }
                    }
                }
            }
        }
    }

    /**
     * 触发 STT → NMT 推理，推送结果到 Flutter。
     * 在 inferenceExecutor 线程中运行（串行）。
     *
     * 来源：A-006 第六章 6.2 F6、F7
     */
    private fun triggerSttAndNmt() {
        if (speechAccumulator.isEmpty()) return

        // 取出语音段，清空积累池
        val speechSamples = speechAccumulator.toShortArray()
        speechAccumulator.clear()

        // ── F6：STT 调用 ──────────────────────────────────────────────────────
        // 来源：A-006 第二章 2.4 — WhisperInference.transcribe(ShortArray, language): String
        // 来源：WhisperInference.kt（已锁死）
        val whisper = whisperInference ?: return
        val sttText = try {
            whisper.transcribe(speechSamples, srcLang)
        } catch (e: Exception) {
            Log.e(TAG, "STT 推理失败：${e.message}", e)
            return
        }

        Log.d(TAG, "STT 结果：$sttText")

        // 来源：A-006 第四章 4.2 — EventSink.success() 必须在主线程
        if (sttText.isNotBlank()) {
            mainHandler.post {
                sttEventSink?.success(sttText)
            }
        }

        // ── F7：NMT 调用 ──────────────────────────────────────────────────────
        // 来源：A-006 第三章 3.1 — OpusMTInference.translate(String): String
        // 来源：OpusMTInference.kt（已锁死），胶水层直接传 STT 结果即可
        if (sttText.isBlank()) return
        val opusMT = opusMTInference ?: return
        val nmtText = try {
            opusMT.translate(sttText)
        } catch (e: Exception) {
            Log.e(TAG, "NMT 推理失败：${e.message}", e)
            return
        }

        Log.d(TAG, "NMT 结果：$nmtText")

        // 来源：A-006 第四章 4.2 — EventSink.success() 必须在主线程
        if (nmtText.isNotBlank()) {
            mainHandler.post {
                nmtEventSink?.success(nmtText)
            }
        }
    }
}
