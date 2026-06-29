// SileroVAD.kt
// GloTalk-V3 | 节点 1：语音活动检测（VAD）
// 模型：silero_vad.onnx（v4）
// 来源：https://github.com/snakers4/silero-vad
// OnnxRuntime Java API：https://onnxruntime.ai/docs/get-started/with-java.html
// 查证报告：A-004 第二部分 VAD-1 ~ VAD-6

package tech.glotalk.glotalk_v3

import ai.onnxruntime.OnnxTensor      // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtEnvironment   // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtSession       // https://onnxruntime.ai/docs/get-started/with-java.html
import android.content.Context
import java.io.File
import java.nio.file.Files

/**
 * Silero VAD v4 推理封装
 *
 * 输入规格（来源：A-004 VAD-1，GitHub Discussion #216，snakers4 官方回复）：
 *   "input"  float32 [1, 512]   — PCM 音频帧，归一化到 [-1, 1]
 *   "sr"     int64   [1]        — 采样率，固定值 16000
 *   "h"      float32 [2, 1, 128]— LSTM 隐状态（初始全零）
 *   "c"      float32 [2, 1, 128]— LSTM 细胞状态（初始全零）
 *
 * 输出规格（来源：A-004 VAD-1）：
 *   "output" float32 [1, 1]    — 语音概率 [0, 1]
 *   "hn"     float32 [2, 1, 128]— 更新后 LSTM 隐状态
 *   "cn"     float32 [2, 1, 128]— 更新后 LSTM 细胞状态
 *
 * 注意：h/c 状态必须在每次推理后更新，跨帧保持（来源：A-004 VAD-2，官方 Python OnnxWrapper.reset_states()）
 */
class SileroVAD(private val context: Context) {

    // 模型常量（来源：A-004 VAD-1，VAD-3）
    companion object {
        private const val MODEL_ASSET_PATH = "models/silero_vad.onnx"
        private const val SAMPLE_RATE = 16000L          // sr 固定值（来源：A-004 VAD-1）
        private const val CHUNK_SIZE = 512              // 32ms @16kHz（来源：A-004 VAD-3）
        private const val H_C_SIZE = 2 * 1 * 128       // [2,1,128] 展平（来源：A-004 VAD-1）
        const val SPEECH_THRESHOLD = 0.5f              // 语音概率阈值（来源：A-004 VAD-4）
    }

    // OrtEnvironment 全局单例（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null

    // LSTM 状态（来源：A-004 VAD-2，官方 Python OnnxWrapper.reset_states()）
    // 初始化为全零，每次推理后用 hn/cn 更新
    private var h = FloatArray(H_C_SIZE) { 0f }
    private var c = FloatArray(H_C_SIZE) { 0f }

    // 采样率张量，整个生命周期固定不变，创建一次复用
    private var srTensorCached: OnnxTensor? = null

    // h/c 张量形状（来源：A-004 VAD-1）
    private val hcShape = longArrayOf(2, 1, 128)

    /**
     * 加载模型
     * 小模型（约 2MB），直接从 assets 读取 ByteArray（来源：A-004 C-1 方式 A）
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun loadModel() {
        // 读取 assets 中的模型字节（来源：A-004 C-1 方式 A）
        val modelBytes: ByteArray = context.assets.open(MODEL_ASSET_PATH).readBytes()

        // 创建会话（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(1)  // VAD 轻量，1 线程足够
        }
        session = env.createSession(modelBytes, options)

        // 预创建 sr 张量（固定值，复用）（来源：A-004 VAD-1）
        val srArray = longArrayOf(SAMPLE_RATE)
        srTensorCached = OnnxTensor.createTensor(env, srArray, longArrayOf(1))
    }

    /**
     * 重置 LSTM 状态（开始新语句时调用）
     * 来源：A-004 VAD-2，官方 Python OnnxWrapper.reset_states()
     * 参考：https://github.com/snakers4/silero-vad
     */
    fun resetState() {
        h = FloatArray(H_C_SIZE) { 0f }
        c = FloatArray(H_C_SIZE) { 0f }
    }

    /**
     * 判断当前帧是否含有语音
     *
     * @param pcmShorts PCM_16BIT 音频帧（AudioRecord 输出的 ShortArray）
     * @return 语音概率 [0, 1]，>= SPEECH_THRESHOLD 则为有效语音
     *
     * 资源管理：每次推理后必须 close 所有张量（来源：A-004 C-3，C-2）
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun isSpeech(pcmShorts: ShortArray): Float {
        checkNotNull(session) { "SileroVAD: session 未初始化，请先调用 loadModel()" }
        require(pcmShorts.size == CHUNK_SIZE) {
            "SileroVAD: 输入帧大小应为 $CHUNK_SIZE，实际为 ${pcmShorts.size}"
        }

        // Step 1：ByteArray → FloatArray 归一化（来源：A-004 VAD-5）
        // AudioRecord 返回 PCM_16BIT ShortArray，归一化到 [-1.0, 1.0]
        // 参考：https://github.com/snakers4/silero-vad （Python 官方归一化逻辑）
        val floatFrame: FloatArray = shortArrayToFloat(pcmShorts)

        // Step 2：创建 "input" 张量 [1, 512]（来源：A-004 VAD-1）
        val inputTensor = OnnxTensor.createTensor(
            env, floatFrame, longArrayOf(1, CHUNK_SIZE.toLong())
        )

        // Step 3：创建 "h" 张量 [2,1,128]（来源：A-004 VAD-2）
        val hTensor = OnnxTensor.createTensor(env, h, hcShape)

        // Step 4：创建 "c" 张量 [2,1,128]（来源：A-004 VAD-2）
        val cTensor = OnnxTensor.createTensor(env, c, hcShape)

        // Step 5：推理，必须在 finally 中 close 所有张量（来源：A-004 C-3）
        var speechProbability = 0f
        try {
            // 组装输入（来源：A-004 VAD-1，官方 Python ort_inputs）
            val inputs = mapOf(
                "input" to inputTensor,
                "sr"    to srTensorCached!!,  // 复用缓存的 sr 张量
                "h"     to hTensor,
                "c"     to cTensor
            )

            // 执行推理（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
            val results = session!!.run(inputs)
            results.use {
                // 读取语音概率 output[1,1]（来源：A-004 VAD-1 输出规格）
                val outputProb = (results[0].value as Array<FloatArray>)[0][0]
                speechProbability = outputProb

                // 更新 LSTM 状态（来源：A-004 VAD-2）
                // hn → 下次的 h，cn → 下次的 c
                // Python 官方：out, self._h, self._c = ort_outs
                // 来源：https://github.com/snakers4/silero-vad
                h = (results[1].value as Array<FloatArray>).flatMap { it.toList() }.toFloatArray()
                c = (results[2].value as Array<FloatArray>).flatMap { it.toList() }.toFloatArray()
            }
        } finally {
            // 必须 close 所有 OnnxTensor（来源：A-004 C-3，官方 Java API 文档）
            inputTensor.close()  // close inputTensor
            hTensor.close()      // close hTensor
            cTensor.close()      // close cTensor
            // srTensorCached 生命周期由 close() 统一管理，不在此 close
        }

        return speechProbability
    }

    /**
     * PCM_16BIT ShortArray → FloatArray 归一化
     * 来源：A-004 VAD-5
     * 参考：https://github.com/snakers4/silero-vad（Python 官方归一化逻辑）
     * AudioRecord 返回 Short [-32768, 32767]，除以 32768.0f 归一化到 [-1.0, 1.0]
     */
    private fun shortArrayToFloat(shorts: ShortArray): FloatArray {
        return FloatArray(shorts.size) { i ->
            shorts[i].toFloat() / 32768.0f
        }
    }

    /**
     * 释放所有资源
     * 来源：A-004 C-3（OrtSession 生命周期结束时必须 close）
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun close() {
        srTensorCached?.close()  // close 预创建的 sr 张量
        srTensorCached = null
        session?.close()         // close OrtSession（来源：A-004 C-3）
        session = null
    }
}
