// GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/MainActivity.kt
// 智能体 B 代码编辑 | 依据：查证报告 A-003 | 任务：B-003

package tech.glotalk.glotalk_v3

// Flutter 嵌入层 — https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html
import io.flutter.embedding.android.FlutterActivity
// Flutter 引擎 — https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterEngine.html
import io.flutter.embedding.engine.FlutterEngine
// MethodChannel — https://docs.flutter.dev/platform-integration/platform-channels
import io.flutter.plugin.common.MethodChannel
// EventChannel — https://docs.flutter.dev/platform-integration/platform-channels
import io.flutter.plugin.common.EventChannel

// AudioRecord — https://developer.android.com/reference/android/media/AudioRecord
import android.media.AudioRecord
// AudioFormat — https://developer.android.com/reference/android/media/AudioFormat
import android.media.AudioFormat
// MediaRecorder.AudioSource — https://developer.android.com/reference/android/media/MediaRecorder.AudioSource
import android.media.MediaRecorder

// TextToSpeech — https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
import android.speech.tts.TextToSpeech
// Locale — 标准 Java，用于设置 TTS 语言
import java.util.Locale
// Handler / Looper — https://developer.android.com/reference/android/os/Handler
import android.os.Handler
import android.os.Looper

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

    // C3 — EventChannel：PCM List<int> 音频帧流
    private val AUDIO_STREAM_CHANNEL = "tech.glotalk/audio_stream"

    // C4 — EventChannel：STT 文字流 + VAD 前缀标记 ([VAD:SPEECH] / [VAD:SILENCE])
    private val STT_RESULT_CHANNEL = "tech.glotalk/stt_result"

    // C5 — EventChannel：NMT 翻译文字流
    private val NMT_RESULT_CHANNEL = "tech.glotalk/nmt_result"

    // ─────────────────────────────────────────────────────────────────────────
    // EventSink 引用（查证报告 A-003 第三章 §3.2）
    // EventSink.success() 必须在主线程调用
    // ─────────────────────────────────────────────────────────────────────────

    // C3 — 音频流 EventSink
    private var audioEventSink: EventChannel.EventSink? = null

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
    // AudioRecord — https://developer.android.com/reference/android/media/AudioRecord
    // ─────────────────────────────────────────────────────────────────────────

    // Whisper 要求 16kHz 单声道 PCM_16BIT
    // 来源：https://github.com/microsoft/onnxruntime-inference-examples/tree/main/mobile/examples/speech_recognition/android
    private val SAMPLE_RATE = 16000
    private val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
    private val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT

    private var audioRecord: AudioRecord? = null
    private var isRecording: Boolean = false

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
                    // 查证报告 A-003 第二章 §2.3
                    "ping" -> {
                        result.success("pong")
                    }

                    // 测试2：OnnxRuntime 加载验证
                    // 来源：https://onnxruntime.ai/docs/get-started/with-java.html
                    "testOnnxRuntime" -> {
                        try {
                            // OrtEnvironment.getEnvironment() 是全局单例
                            // 来源：https://onnxruntime.ai/docs/get-started/with-java.html
                            val env = OrtEnvironment.getEnvironment()
                            // 成功获取环境即表示 OnnxRuntime native 层加载正常
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

                    // initModels：初始化 VAD/STT/NMT 模型（桩位）
                    // 查证报告 A-003 第八章 §8.4
                    "initModels" -> {
                        // call.argument 用法：https://api.flutter.dev/javadoc/io/flutter/plugin/common/MethodCall.html
                        val srcLang = call.argument<String>("srcLang") ?: "en"
                        val tgtLang = call.argument<String>("tgtLang") ?: "zh"
                        // TODO: 初始化 WhisperInference(srcLang)
                        // TODO: 初始化 OpusMTInference(srcLang, tgtLang)
                        // TODO: 初始化 SileroVAD
                        android.util.Log.d("GloTalk", "initModels: $srcLang → $tgtLang")
                        result.success(true)
                    }

                    // startRecording：启动麦克风采集
                    // 来源：https://developer.android.com/reference/android/media/AudioRecord
                    "startRecording" -> {
                        startAudioCapture()
                        result.success(true)
                    }

                    // stopRecording：停止麦克风采集
                    // 来源：https://developer.android.com/reference/android/media/AudioRecord
                    "stopRecording" -> {
                        stopAudioCapture()
                        result.success(true)
                    }

                    // speakText：TTS 播放翻译结果（测试7）
                    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
                    // 查证报告 A-003 第五章 §5.2 & §5.4
                    "speakText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val lang = call.argument<String>("lang") ?: "zh"
                        if (ttsReady && text.isNotEmpty()) {
                            // setLanguage — https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech#setLanguage(java.util.Locale)
                            tts?.language = when (lang) {
                                "zh" -> Locale.CHINESE
                                "en" -> Locale.ENGLISH
                                "ja" -> Locale.JAPANESE
                                else -> Locale(lang)
                            }
                            // speak 四参数版本（API 21+，minSdk 24 满足）
                            // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech#speak(kotlin.String,kotlin.Int,android.os.Bundle,kotlin.String)
                            // QUEUE_FLUSH：清空队列，立即朗读（实时翻译场景）
                            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, null)
                        }
                        result.success(true)
                    }

                    // stopTts：停止当前 TTS 朗读
                    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech#stop()
                    "stopTts" -> {
                        tts?.stop()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        // ─────────────────────────────────────────────────────────────────────
        // C3 — EventChannel：tech.glotalk/audio_stream（PCM 音频帧流）
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // ─────────────────────────────────────────────────────────────────────
        EventChannel(messenger, AUDIO_STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                // onListen：Dart 侧调用 receiveBroadcastStream().listen() 时触发
                // 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/EventChannel.StreamHandler.html
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    audioEventSink = events
                }
                // onCancel：Dart 侧取消订阅时触发
                override fun onCancel(arguments: Any?) {
                    audioEventSink = null
                }
            })

        // ─────────────────────────────────────────────────────────────────────
        // C4 — EventChannel：tech.glotalk/stt_result（STT 文字流 + VAD 前缀）
        // 来源：https://docs.flutter.dev/platform-integration/platform-channels
        // 查证报告 A-003 第六章 §6.2 测试4 说明
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
    // onDestroy：释放 TTS 资源，防止内存泄漏
    // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech#shutdown()
    // 查证报告 A-003 第五章 §5.3
    // ─────────────────────────────────────────────────────────────────────────
    override fun onDestroy() {
        tts?.shutdown()
        tts = null
        stopAudioCapture()
        super.onDestroy()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AudioRecord 辅助方法
    // 来源：https://developer.android.com/reference/android/media/AudioRecord
    // 工作手册第五章 §5.2
    // ─────────────────────────────────────────────────────────────────────────

    private fun startAudioCapture() {
        if (isRecording) return

        // getMinBufferSize — https://developer.android.com/reference/android/media/AudioRecord#getMinBufferSize(int,int,int)
        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT
        )

        // AudioRecord 构造函数
        // 来源：https://developer.android.com/reference/android/media/AudioRecord#AudioRecord(int,int,int,int,int)
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT,
            bufferSize
        )

        // startRecording — https://developer.android.com/reference/android/media/AudioRecord#startRecording()
        audioRecord?.startRecording()
        isRecording = true

        // 在后台线程持续读取 PCM 数据，推送到 Flutter
        Thread {
            val buffer = ShortArray(bufferSize / 2)
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (read > 0) {
                    // 转换为 List<int> 推送（工作手册 §5.3，查证报告 A-003 §3.4）
                    val pcmList = buffer.take(read).map { it.toInt() }

                    // EventSink.success() 必须在主线程调用
                    // 来源：https://docs.flutter.dev/platform-integration/platform-channels#channels-and-platform-threading
                    // 查证报告 A-003 第三章 §3.3
                    Handler(Looper.getMainLooper()).post {
                        audioEventSink?.success(pcmList)
                    }

                    // TODO: 将 pcmList 传入 SileroVAD 推理
                    // TODO: 根据 VAD 结果决定是否送入 Whisper STT
                    // TODO: STT 结果送入 Opus-MT NMT
                }
            }
        }.start()
    }

    private fun stopAudioCapture() {
        isRecording = false
        // stop — https://developer.android.com/reference/android/media/AudioRecord#stop()
        audioRecord?.stop()
        // release — https://developer.android.com/reference/android/media/AudioRecord#release()
        audioRecord?.release()
        audioRecord = null
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 推送辅助方法（供后续 STT/NMT 推理模块调用）
    // 查证报告 A-003 第八章 §8.1
    // EventSink.success() 必须在主线程：https://docs.flutter.dev/platform-integration/platform-channels
    // ─────────────────────────────────────────────────────────────────────────

    // 推送 STT 识别文本（测试5）
    fun pushSttResult(text: String) {
        runOnUiThread {
            sttEventSink?.success(text)
        }
    }

    // 推送 NMT 翻译文本（测试6）
    fun pushNmtResult(text: String) {
        runOnUiThread {
            nmtEventSink?.success(text)
        }
    }

    // 推送 VAD 状态（测试4）
    // 查证报告 A-003 第六章 §6.2 测试4：通过 C4 (stt_result) 传递，用 [VAD:] 前缀区分
    fun pushVadStatus(isSpeech: Boolean) {
        val marker = if (isSpeech) "[VAD:SPEECH]" else "[VAD:SILENCE]"
        runOnUiThread {
            sttEventSink?.success(marker)
        }
    }
}
