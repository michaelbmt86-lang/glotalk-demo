// SileroVAD.kt
// GloTalk-V3 | 节点 1：语音活动检测（VAD）
// 模型：silero_vad.onnx（v5，来自 onnx-community/silero-vad）
// 来源：https://github.com/snakers4/silero-vad
// OnnxRuntime Java API：https://onnxruntime.ai/docs/get-started/with-java.html
// 查证报告：A-004 第二部分 VAD-1 ~ VAD-6

package tech.glotalk.glotalk_v3

import ai.onnxruntime.OnnxTensor      // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtEnvironment   // https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtSession       // https://onnxruntime.ai/docs/get-started/with-java.html
import android.content.Context
import java.nio.FloatBuffer            // A-004-补丁：OnnxTensor.createTensor(env, FloatBuffer, shape)
import java.nio.LongBuffer             // A-004-补丁：OnnxTensor.createTensor(env, LongBuffer, shape)

/**
 * Silero VAD v5 推理封装
 *
 * A-015修正：下载的 model.onnx 是 v5 格式（非 v4）
 * 来源：A-015 查证报告 Q1 — Xenova 官方 transformers.js 示例确认 v5 接口
 * 来源：https://github.com/snakers4/silero-vad/blob/master/examples/c++/silero.cc
 *
 * 输入规格（来源：A-015 Q1/Q3，官方 C++ 示例 + Xenova transformers.js 示例）：
 *   "input"  float32 [1, 512]   — PCM 音频帧，归一化到 [-1, 1]
 *   "sr"     int64   [1]        — 采样率，固定值 16000
 *   "state"  float32 [2, 1, 128]— 合并的 LSTM 状态（v5 将 h/c 合并为单一 state）
 *
 * 输出规格（来源：A-015 Q1/Q3）：
 *   "output" float32 [1, 1]    — 语音概率 [0, 1]
 *   "stateN" float32 [2, 1, 128]— 更新后的 LSTM 状态，下次推理作为 state 输入
 *
 * 注意：state 必须在每次推理后用 stateN 更新，跨帧保持
 * 官方 Python：self._state = ort_outs[1]
 * 来源：utils_vad.py master branch
 */
class SileroVAD(private val context: Context) {

    // 模型常量（来源：A-004 VAD-1，VAD-3）
    companion object {
        // B-009修正：MODEL_ASSET_PATH 已移除，模型在 app_flutter/models/ 不在 assets
        // 手机实际文件名（来源：main.dart _modelFiles 下载清单）
        private const val MODEL_FILE_NAME = "silero_vad.onnx"
        private const val SAMPLE_RATE = 16000L          // sr 固定值（来源：A-004 VAD-1）
        private const val CHUNK_SIZE = 512              // 32ms @16kHz（来源：A-004 VAD-3）
        private const val H_C_SIZE = 2 * 1 * 128       // [2,1,128] 展平，v5 state 张量大小（来源：A-015 Q1）
        const val SPEECH_THRESHOLD = 0.5f              // 语音概率阈值（来源：A-004 VAD-4）
    }

    // OrtEnvironment 全局单例（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null

    // LSTM 状态（来源：A-015 Q1/Q4 — v5 将 h/c 合并为单一 state 张量）
    // 初始化为全零，每次推理后用 stateN 更新
    // 官方 Python：self._state = np.zeros((2, 1, 128), dtype='float32')
    private var state = FloatArray(H_C_SIZE) { 0f }

    // 采样率张量，整个生命周期固定不变，创建一次复用
    private var srTensorCached: OnnxTensor? = null

    // state 张量形状 [2,1,128]（来源：A-015 Q1，官方 C++ state_node_dims = {2,1,128}）
    private val stateShape = longArrayOf(2, 1, 128)

    /**
     * 加载模型
     * 小模型（约 2MB），直接从 assets 读取 ByteArray（来源：A-004 C-1 方式 A）
     * 来源：https://onnxruntime.ai/docs/get-started/with-java.html
     */
    fun loadModel() {
        // B-009修正：路径改为 app_flutter/models/，与 Flutter 下载目录一致
        // Flutter getApplicationDocumentsDirectory() = filesDir.parent/app_flutter/
        // 来源：A-008 查证报告，path_provider 路径对照分析
        val modelFile = java.io.File(context.filesDir.parentFile, "app_flutter/models/${MODEL_FILE_NAME}")
        val modelBytes: ByteArray = modelFile.readBytes()

        // 创建会话（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(1)  // VAD 轻量，1 线程足够
        }
        session = env.createSession(modelBytes, options)

        // 预创建 sr 张量（固定值，复用）（来源：A-004 VAD-1）
        val srArray = longArrayOf(SAMPLE_RATE)
        // A-004-补丁：LongBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
        srTensorCached = OnnxTensor.createTensor(env, LongBuffer.wrap(srArray), longArrayOf(1))
    }

    /**
     * 重置 LSTM 状态（开始新语句时调用）
     * 来源：A-004 VAD-2，官方 Python OnnxWrapper.reset_states()
     * 参考：https://github.com/snakers4/silero-vad
     */
    fun resetState() {
        // A-015修正：v5 只有单一 state 字段，重置为全零
        // 来源：A-015 Q4 — 官方 Python reset_states()：self._state = np.zeros((2,1,128))
        state = FloatArray(H_C_SIZE) { 0f }
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
        // A-004-补丁：FloatBuffer.wrap() — https://onnxruntime.ai/docs/get-started/with-java.html
        val inputTensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(floatFrame), longArrayOf(1, CHUNK_SIZE.toLong())
        )

        // Step 3：创建 "state" 张量 [2,1,128]（来源：A-015 Q1/Q4）
        // A-015修正：v5 将 h/c 合并为单一 state 张量
        // 官方 C++ state_node_dims = {2,1,128}，名称 "state"
        // 来源：https://github.com/snakers4/silero-vad/blob/master/examples/c++/silero.cc
        val stateTensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(state), stateShape)

        // Step 4：推理，必须在 finally 中 close 所有张量（来源：A-004 C-3）
        var speechProbability = 0f
        try {
            // 组装输入（来源：A-015 Q1 — v5 接口：input, sr, state 共3个输入）
            // 官方 Python：ort_inputs = {'input': x, 'state': self._state, 'sr': sr_array}
            // 来源：utils_vad.py master branch
            val inputs = mapOf(
                "input" to inputTensor,
                "sr"    to srTensorCached!!,  // 复用缓存的 sr 张量
                "state" to stateTensor        // v5：单一合并状态张量
            )

            // 执行推理（来源：https://onnxruntime.ai/docs/get-started/with-java.html）
            val results = session!!.run(inputs)
            results.use {
                // 读取语音概率 output[1,1]（索引0，来源：A-015 Q4）
                val outputProb = (results[0].value as Array<FloatArray>)[0][0]
                speechProbability = outputProb

                // 更新 state（来源：A-015 Q4，A-016 Q1/Q2）
                // v5：stateN 在索引1，shape [2,1,128]，三维张量
                // A-016修正：getValue() 对三维张量返回 Array<Array<FloatArray>>
                //   原写法 as Array<FloatArray> 是错误 cast，运行时抛 ClassCastException
                //   官方 Javadoc 推荐：超过2维用 getFloatBuffer() 读取扁平 FloatBuffer
                //   来源：https://onnxruntime.ai/docs/api/java/ai/onnxruntime/OnnxTensor.html
                //   来源：A-016 Q2 — getFloatBuffer() 返回行优先扁平 FloatBuffer，256个元素
                state = (results[1] as ai.onnxruntime.OnnxTensor)
                    .floatBuffer
                    .let { buf ->
                        FloatArray(buf.remaining()).also { buf.get(it) }
                    }
            }
        } finally {
            // 必须 close 所有 OnnxTensor（来源：A-004 C-3，官方 Java API 文档）
            inputTensor.close()   // close inputTensor
            stateTensor.close()   // close stateTensor（A-015修正：替代原 hTensor+cTensor）
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
