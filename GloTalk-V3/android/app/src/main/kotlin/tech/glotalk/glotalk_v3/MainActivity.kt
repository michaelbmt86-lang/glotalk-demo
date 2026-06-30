// GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/MainActivity.kt
// 智能体 B 代码编辑 | 依据：查证报告 A-003、A-006 | 任务：B-003、B-006
// B-006 集成改动：接入 PipelineOrchestrator，填写 initModels TODO，
//                 AudioService 回调改为 onPcmData，补充 onDestroy destroy()

package tech.glotalk.glotalk_v3

// Flutter 嵌入层 — https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html
import io.flutter.embedding.android.FlutterActivity
// Flutter 引擎 — https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterEngine.html
import io.flutter.embedding.engine.FlutterEngine
// MethodChannel — https://docs.flutter.dev/platform-integration/platform-channels
import io.flutter.plugin.common.MethodChannel
// EventChannel — https://docs.flutter.dev/platform-integration/platform-channels
import io.flutter.plugin.common.EventChannel

// TextToSpeech — https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
import android.speech.tts.TextToSpeech
// Locale — 标准 Java，用于设置 TTS 语言
import java.util.Locale

// OrtEnvironment — https://onnxruntime.ai/docs/get-started/with-java.html
import ai.onnxruntime.OrtEnvironment

class MainActivity : FlutterActivity() {

    // ─────────────────────────────────────────────────────────────────────────
    // Channel 名称常量（查证报告 A-003 第四章，铁律：两端字符串完全一致）
    // 来源：https://docs.flutter.dev/platform-integration/platform-channels
    // ─────────────────────────────────────────────────────────────────────────

    // C1 — MethodChannel：ping、testOnnxRuntime
    private val INFERENCE_CHANNEL = "tech.glotalk/inference"

    // C2 — MethodChannel：initModels、startRecording、stopRecording、speakText
    private val CONTROL_CHANNEL = "tech.glotalk/control"

    // C3 — EventChannel：PCM ByteArray 音频帧流
    private val AUDIO_STREAM_CHANNEL = "tech.glotalk/audio_stream"

    // C4 — EventChannel：STT 文字流 + VAD 前缀标记 ([VAD:SPEECH] / [VAD:SILENCE])
    private val STT_RESULT_CHANNEL = "tech.glotalk/stt_result"

    // C5 — EventChannel：NMT 翻译文字流
    private val NMT_RESULT_CHANNEL = "tech.glotalk/nmt_result"

    // ─────────────────────────────────────────────────────────────────────────
    // AudioService 实例
    // ─────────────────────────────────────────────────────────────────────────
    private val audioService = AudioService()

    // ─────────────────────────────────────────────────────────────────────────
    // PipelineOrchestrator — 四节点胶水层（VAD → STT → NMT）
    // 来源：A-006 第六章 6.5 — MainActivity.initModels() 中创建实例
    // B-006 改动 1
    // ─────────────────────────────────────────────────────────────────────────
    // A-017 Q3修正：加 @Volatile 保证主线程写入对 recordThread 立即可见
    // 来源：A-017 Q3 — JLS 17.4 JMM，Kotlin @Volatile 官方文档
    // recordThread 通过 onAudioData lambda 读取此变量，必须有内存屏障
    @Volatile private var pipelineOrchestrator: PipelineOrchestrator? = null

    // ─────────────────────────────────────────────────────────────────────────
    // EventSink 引用（查证报告 A-003 第三章 §3.2）
    // EventSink.success() 必须在主线程调用
    // ─────────────────────────────────────────────────────────────────────────

    // C4 — STT 结果 EventSink（同时传递 VAD 状态前缀）
    private var sttEventSink: EventChannel.EventSink? = null

    // C5 — NMT 结果 EventSink
    private var nmtEventSink: EventChannel.EventSink? = null

    // ─────────────────────────────────────────────────────────────────────────
    // TextToSpeech — https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
    // ─────────────────────────────────────────────────────────────────────────
    private var tts: TextToSpeech? = null
    private var ttsReady: Boolean = false

    // ─────────────────────────────────────────────────────────────────────────
    // configureFlutterEngine
    // 来源：https://docs.flutter.dev/platform-integration/platform-channels
    // 铁律：第一行必须调用 super.configureFlutterEngine(flutterEngine)
    // ─────────────────────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 必须第一行调用 super，否则插件注册失败
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels#step-3-add-an-android-platform-specific-implementation
        super.configureFlutterEngine(flutterEngine)

        // ── TTS 初始化（查证报告 A-003 第五章 §8.2）
        // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
        tts = TextToSpeech(this) { status ->
            ttsReady = (status == TextToSpeech.SUCCESS)
        }

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ─────────────────────────────────────────────────────────────────────
        // C1 — MethodChannel：tech.glotalk/inference
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        MethodChannel(messenger, INFERENCE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // 测试1：连通性测试
                    "ping" -> {
                        result.success("pong")
                    }

                    // 测试2：OnnxRuntime 加载验证
                    // 来源：https://onnxruntime.ai/docs/get-started/with-java.html
                    "testOnnxRuntime" -> {
                        try {
                            val env = OrtEnvironment.getEnvironment()
                            result.success("OnnxRuntime OK: ${env.version}")
                        } catch (e: Exception) {
                            result.success("OnnxRuntime ERROR: ${e.message}")
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ─────────────────────────────────────────────────────────────────────
        // C2 — MethodChannel：tech.glotalk/control
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        MethodChannel(messenger, CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // initModels：创建 PipelineOrchestrator 并初始化四节点模型
                    // 来源：A-006 第六章 6.5 — initModels() 中创建实例并调用 init()
                    // B-006 改动 2：填写原 TODO 占位
                    "initModels" -> {
                        val srcLang = call.argument<String>("srcLang") ?: "zh"
                        val tgtLang = call.argument<String>("tgtLang") ?: "en"
                        pipelineOrchestrator = PipelineOrchestrator(
                            context     = this,
                            sttEventSink = sttEventSink,
                            nmtEventSink = nmtEventSink
                        )
                        pipelineOrchestrator?.init(srcLang, tgtLang)
                        android.util.Log.d("GloTalk", "initModels: $srcLang → $tgtLang")
                        result.success(true)
                    }

                    // startRecording：启动 AudioService 麦克风采集
                    // B-006 改动 3 / B-007a 修正：赋值 onAudioData 回调后再启动
                    // AudioService 内部已通过 D4 修正负责推送 eventSink（测试3）
                    // 此处 onAudioData 仅送入 PipelineOrchestrator，不重复推送 eventSink
                    // 来源：A-006 第六章 6.5、A-007 查证报告
                    "startRecording" -> {
                        audioService.onAudioData = { byteArray ->
                            // 送入四节点流水线（后台线程，Orchestrator 内部 submit 到 inferenceExecutor）
                            pipelineOrchestrator?.onPcmData(byteArray)
                        }
                        val started = audioService.startRecording()
                        if (started) {
                            result.success(true)
                        } else {
                            result.error(
                                "AUDIO_INIT_FAILED",
                                "AudioRecord 初始化失败，请检查麦克风权限或硬件支持",
                                null
                            )
                        }
                    }

                    // stopRecording：停止采集并停止流水线
                    // 来源：A-006 第六章 6.5 — stopPipeline() 中调用 orchestrator.stop()
                    // B-006 改动 4
                    "stopRecording" -> {
                        audioService.stopRecording()
                        // stop() 内部 awaitTermination(3s)，等待推理完成再返回
                        // 来源：B-006c 竞态修复
                        pipelineOrchestrator?.stop()
                        result.success(true)
                    }

                    // speakText：TTS 播放翻译结果
                    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
                    "speakText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val lang = call.argument<String>("lang") ?: "en"
                        if (ttsReady && text.isNotEmpty()) {
                            tts?.language = when (lang) {
                                "zh" -> Locale.CHINESE
                                "en" -> Locale.ENGLISH
                                "ja" -> Locale.JAPANESE
                                else -> Locale(lang)
                            }
                            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, null)
                        }
                        result.success(true)
                    }

                    "stopTts" -> {
                        tts?.stop()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        // ─────────────────────────────────────────────────────────────────────
        // C3 — EventChannel：tech.glotalk/audio_stream（PCM ByteArray 音频帧流）
        // onListen 时把 EventSink 注入 AudioService
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, AUDIO_STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    audioService.eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    audioService.eventSink = null
                }
            })

        // ─────────────────────────────────────────────────────────────────────
        // C4 — EventChannel：tech.glotalk/stt_result（STT 文字流 + VAD 前缀）
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // B-006 改动 6：onListen/onCancel 同步 Sink 给 PipelineOrchestrator
        // 来源：A-006 第六章 6.5
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, STT_RESULT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sttEventSink = events
                    pipelineOrchestrator?.updateSinks(sttEventSink, nmtEventSink)
                }
                override fun onCancel(arguments: Any?) {
                    sttEventSink = null
                    pipelineOrchestrator?.updateSinks(null, nmtEventSink)
                }
            })

        // ─────────────────────────────────────────────────────────────────────
        // C5 — EventChannel：tech.glotalk/nmt_result（NMT 翻译文字流）
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // B-006 改动 6：onListen/onCancel 同步 Sink 给 PipelineOrchestrator
        // 来源：A-006 第六章 6.5
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, NMT_RESULT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    nmtEventSink = events
                    pipelineOrchestrator?.updateSinks(sttEventSink, nmtEventSink)
                }
                override fun onCancel(arguments: Any?) {
                    nmtEventSink = null
                    pipelineOrchestrator?.updateSinks(sttEventSink, null)
                }
            })
    }

    // ─────────────────────────────────────────────────────────────────────────
    // onDestroy：释放所有资源
    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech#shutdown()
    // B-006 改动 5：加入 orchestrator.destroy()
    // 来源：A-006 第六章 6.3 — onDestroy() 时 shutdownNow() + close 模型
    // ─────────────────────────────────────────────────────────────────────────
    override fun onDestroy() {
        tts?.shutdown()
        tts = null
        audioService.stopRecording()
        // destroy() 内部：shutdownNow() → close VAD/Whisper/OpusMT
        // 必须在 super.onDestroy() 之前，避免 Activity 上下文失效
        // 来源：A-006 第六章 6.3
        pipelineOrchestrator?.destroy()
        pipelineOrchestrator = null
        super.onDestroy()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 推送辅助方法（保留，供调试或未来直接调用）
    // EventSink.success() 必须在主线程
    // 来源：https://docs.flutter.dev/platform-integration/platform-channels
    // ─────────────────────────────────────────────────────────────────────────

    fun pushSttResult(text: String) {
        runOnUiThread {
            sttEventSink?.success(text)
        }
    }

    fun pushNmtResult(text: String) {
        runOnUiThread {
            nmtEventSink?.success(text)
        }
    }

    fun pushVadStatus(isSpeech: Boolean) {
        val marker = if (isSpeech) "[VAD:SPEECH]" else "[VAD:SILENCE]"
        runOnUiThread {
            sttEventSink?.success(marker)
        }
    }
}
