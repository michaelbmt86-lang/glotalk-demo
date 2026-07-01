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
import java.util.concurrent.LinkedBlockingDeque
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
    // A-017 Q4修正：改用 LinkedBlockingDeque，线程安全，支持 stop() 主线程 clear()
    // 来源：A-017 Q4 — ArrayList 非线程安全，官方推荐 LinkedBlockingDeque
    private val vadAccumulator = LinkedBlockingDeque<Short>()

    // 来源：A-006 第六章 6.2 F4 — 语音段积累池
    // A-017 Q4修正：同上
    private val speechAccumulator = LinkedBlockingDeque<Short>()

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
     */
    fun init(srcLang: String, tgtLang: String) {
        this.srcLang = srcLang
        this.tgtLang = tgtLang

        // 来源：A-006 第四章 4.1 — 单线程 Executor，VAD LSTM 状态非线程安全
        inferenceExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "inference-pipeline")
        }

        inferenceExecutor?.submit {
            try {
                sileroVAD = SileroVAD(context)
                sileroVAD?.loadModel()
                Log.d(TAG, "VAD 模型加载完成")

                whisperInference = WhisperInference(context)
                whisperInference?.loadModel()
                Log.d(TAG, "Whisper 模型加载完成")

                opusMTInference = OpusMTInference(context)
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
     */
    fun onPcmData(byteArray: ByteArray) {
        inferenceExecutor?.submit {
            processPcmChunk(byteArray)
        }
    }

    /**
     * 停止流水线（stopRecording 时调用）。
     * B-009修正：不置 inferenceExecutor = null，保持 executor 存活。
     * 这样再次点「开始录音」时 onPcmData() 的 submit 仍然有效。
     * executor 真正销毁只在 destroy()（Activity onDestroy）时执行。
     *
     * 来源：A-006 第六章 6.3
     */
    fun stop() {
        // 先 shutdown + awaitTermination，确保后台线程完全停止
        // A-017 Q4修正：clear() 必须在 awaitTermination() 之后，避免与后台线程并发
        // 来源：A-017 Q4 — stop() 中 clear 时序必须在 awaitTermination 之后
        inferenceExecutor?.shutdown()
        inferenceExecutor?.awaitTermination(3, TimeUnit.SECONDS)

        // 后台线程已停止，安全清空缓冲区和重置状态机
        sileroVAD?.resetState()
        vadState = VadState.IDLE
        silenceSampleCount = 0
        vadAccumulator.clear()
        speechAccumulator.clear()

        // 重新创建 executor 供下次录音使用
        inferenceExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "inference-pipeline")
        }

        Log.d(TAG, "流水线已停止")
    }

    /**
     * 强制关闭（onDestroy 调用）。
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
     * 更新 EventSink 引用。
     */
    fun updateSinks(
        stt: EventChannel.EventSink?,
        nmt: EventChannel.EventSink?
    ) {
        sttEventSink = stt
        nmtEventSink = nmt
    }

    // ─── 内部流水线核心 ───────────────────────────────────────────────────────

    private fun processPcmChunk(byteArray: ByteArray) {
        val shorts = ShortArray(byteArray.size / 2) { i ->
            val lo = byteArray[i * 2].toInt() and 0xFF
            val hi = byteArray[i * 2 + 1].toInt()
            (lo or (hi shl 8)).toShort()
        }

        for (s in shorts) {
            vadAccumulator.addLast(s)  // A-017 Q4: LinkedBlockingDeque API
        }

        while (vadAccumulator.size >= VAD_FRAME_SIZE) {
            // A-017 Q4: LinkedBlockingDeque — 取前512帧并移除
            val frame = ShortArray(VAD_FRAME_SIZE) { vadAccumulator.pollFirst()!! }

            val vad = sileroVAD ?: continue
            val prob = vad.isSpeech(frame)

            when (vadState) {

                VadState.IDLE -> {
                    if (prob >= VAD_POSITIVE_THRESHOLD) {
                        vadState = VadState.SPEECH
                        silenceSampleCount = 0
                        for (s in frame) speechAccumulator.addLast(s)
                        Log.d(TAG, "VAD: IDLE → SPEECH（prob=${"%.3f".format(prob)}）")
                        // A-018 Q4：推送 [VAD:SPEECH] 到 Flutter UI，更新测试4显示
                        // 来源：A-018 Q4-D — 复用 stt_result Channel，mainHandler 切主线程
                        // main.dart _subscribeToSttChannel() 已有 [VAD:SPEECH] 前缀处理逻辑
                        mainHandler.post { sttEventSink?.success("[VAD:SPEECH]") }
                    }
                }

                VadState.SPEECH -> {
                    if (prob >= VAD_NEGATIVE_THRESHOLD) {
                        for (s in frame) speechAccumulator.addLast(s)
                        if (speechAccumulator.size >= MAX_SPEECH_SAMPLES) {
                            Log.d(TAG, "VAD: 语音段达到上限，强制触发 STT")
                            triggerSttAndNmt()
                            vadState = VadState.IDLE
                        }
                    } else {
                        vadState = VadState.SILENCE_END
                        silenceSampleCount = VAD_FRAME_SIZE
                        Log.d(TAG, "VAD: SPEECH → SILENCE_END（prob=${"%.3f".format(prob)}）")
                    }
                }

                VadState.SILENCE_END -> {
                    if (prob >= VAD_NEGATIVE_THRESHOLD) {
                        vadState = VadState.SPEECH
                        silenceSampleCount = 0
                        for (s in frame) speechAccumulator.addLast(s)
                        Log.d(TAG, "VAD: SILENCE_END → SPEECH（迟滞保护，prob=${"%.3f".format(prob)}）")
                    } else {
                        silenceSampleCount += VAD_FRAME_SIZE
                        for (s in frame) speechAccumulator.addLast(s)
                        if (silenceSampleCount >= MIN_SILENCE_SAMPLES) {
                            if (speechAccumulator.isNotEmpty()) {
                                Log.d(TAG, "VAD: 静音超时，触发 STT")
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

    private fun triggerSttAndNmt() {
        if (speechAccumulator.isEmpty()) return

        // A-018 Q4：推送 [VAD:PROCESSING] 到 Flutter UI，表示"正在识别中"
        // 来源：A-018 Q4-D — STT 推理开始前通知 UI，用户知道 App 在处理
        mainHandler.post { sttEventSink?.success("[VAD:PROCESSING]") }

        // A-017 Q4: LinkedBlockingDeque 无 toShortArray()，手动转换
        val speechSamples = ShortArray(speechAccumulator.size) { speechAccumulator.pollFirst()!! }
        // pollFirst 已取出所有元素，队列自然为空，无需 clear()

        val whisper = whisperInference ?: return
        val sttText = try {
            whisper.transcribe(speechSamples, srcLang)
        } catch (e: Exception) {
            Log.e(TAG, "STT 推理失败：${e.message}", e)
            return
        }

        Log.d(TAG, "STT 结果：$sttText")

        if (sttText.isNotBlank()) {
            mainHandler.post {
                sttEventSink?.success(sttText)
            }
        }

        if (sttText.isBlank()) return
        val opusMT = opusMTInference ?: return
        val nmtText = try {
            opusMT.translate(sttText)
        } catch (e: Exception) {
            Log.e(TAG, "NMT 推理失败：${e.message}", e)
            return
        }

        Log.d(TAG, "NMT 结果：$nmtText")

        if (nmtText.isNotBlank()) {
            mainHandler.post {
                nmtEventSink?.success(nmtText)
            }
        }
    }
}
