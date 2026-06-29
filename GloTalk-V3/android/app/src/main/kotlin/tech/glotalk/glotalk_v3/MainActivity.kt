// GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/MainActivity.kt
// 智能体 B 代码编辑 | 依据：查证报告 A-003 | 任务：B-003
// 修正：改用 AudioService 处理麦克风采集，移除 MainActivity 内的重复 AudioRecord 实现

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
    // AudioService 实例（修正：使用 AudioService 处理麦克风采集）
    // AudioService 内部已处理 D1/D2/D3/D4/D5 所有修正项
    // ─────────────────────────────────────────────────────────────────────────
    private val audioService = AudioService()

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

                    "initModels" -> {
                        val srcLang = call.argument<String>("srcLang") ?: "en"
                        val tgtLang = call.argument<String>("tgtLang") ?: "zh"
                        // TODO: 初始化 WhisperInference(srcLang)
                        // TODO: 初始化 OpusMTInference(srcLang, tgtLang)
                        // TODO: 初始化 SileroVAD
                        android.util.Log.d("GloTalk", "initModels: $srcLang → $tgtLang")
                        result.success(true)
                    }

                    // startRecording：调用 AudioService 启动麦克风采集
                    // 修正：改用 AudioService.startRecording()，不再直接使用 AudioRecord
                    "startRecording" -> {
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

                    // stopRecording：调用 AudioService 停止麦克风采集
                    // 修正：改用 AudioService.stopRecording()
                    "stopRecording" -> {
                        audioService.stopRecording()
                        result.success(true)
                    }

                    // speakText：TTS 播放翻译结果
                    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
                    "speakText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val lang = call.argument<String>("lang") ?: "zh"
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
        // 修正：onListen 时把 EventSink 注入 AudioService，由 AudioService 负责推送
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, AUDIO_STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    // 修正：将 EventSink 注入 AudioService
                    // AudioService 内部通过 mainHandler.post{} 确保主线程调用（D4 修正）
                    audioService.eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    // 修正：取消时清空 AudioService 的 EventSink
                    audioService.eventSink = null
                }
            })

        // ─────────────────────────────────────────────────────────────────────
        // C4 — EventChannel：tech.glotalk/stt_result（STT 文字流 + VAD 前缀）
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, STT_RESULT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sttEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    sttEventSink = null
                }
            })

        // ─────────────────────────────────────────────────────────────────────
        // C5 — EventChannel：tech.glotalk/nmt_result（NMT 翻译文字流）
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, NMT_RESULT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    nmtEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    nmtEventSink = null
                }
            })
    }

    // ─────────────────────────────────────────────────────────────────────────
    // onDestroy：释放资源
    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech#shutdown()
    // ─────────────────────────────────────────────────────────────────────────
    override fun onDestroy() {
        tts?.shutdown()
        tts = null
        // 修正：改用 AudioService.stopRecording() 释放麦克风资源
        audioService.stopRecording()
        super.onDestroy()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 推送辅助方法（供后续 STT/NMT 推理模块调用）
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
