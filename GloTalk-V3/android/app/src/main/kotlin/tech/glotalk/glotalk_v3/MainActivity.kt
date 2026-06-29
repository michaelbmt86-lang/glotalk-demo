// =============================================================================
// 文件路径：GloTalk-V3/android/app/src/main/kotlin/tech/glotalk/glotalk_v3/MainActivity.kt
// package：tech.glotalk.glotalk_v3
// 任务编号：B-001 | 依据：智能体 A 查证报告 A-001 | 日期：2026-06-29
// =============================================================================
//
// 本文件职责：
//   - 注册所有 MethodChannel 和 EventChannel
//   - 管理 AudioService 的 EventSink 生命周期（onListen / onCancel）
//   - 向 Flutter 推送 STT / NMT 结果
//
// Channel 名称常量表（来源：GloTalk V3 工作手册 第七章 7.1）：
//   tech.glotalk/control        MethodChannel  初始化、开始/停止录音
//   tech.glotalk/audio_stream   EventChannel   PCM 音频数据流（ByteArray）
//   tech.glotalk/stt_result     EventChannel   STT 实时文本流
//   tech.glotalk/nmt_result     EventChannel   NMT 翻译文本流
//
// 铁律：两端 channel 名称字符串必须完全一致，大小写敏感
// 来源：GloTalk V3 工作手册 第七章 7.1
// =============================================================================

package tech.glotalk.glotalk_v3

// 来源：https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html
import io.flutter.embedding.android.FlutterActivity
// 来源：https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterEngine.html
import io.flutter.embedding.engine.FlutterEngine
// 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/EventChannel.html
import io.flutter.plugin.common.EventChannel
// 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/MethodChannel.html
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // =========================================================================
    // Channel 名称常量
    // 来源：GloTalk V3 工作手册 第七章 7.1 — Channel 名称常量表
    // 铁律：必须与 Dart 侧字符串完全一致，大小写敏感
    // =========================================================================
    private val CONTROL_CHANNEL      = "tech.glotalk/control"
    private val AUDIO_STREAM_CHANNEL = "tech.glotalk/audio_stream"
    private val STT_CHANNEL          = "tech.glotalk/stt_result"
    private val NMT_CHANNEL          = "tech.glotalk/nmt_result"

    // =========================================================================
    // AudioService 实例
    // AudioService 负责 AudioRecord 采集 + ByteArray 转换 + mainHandler 推送
    // =========================================================================
    private val audioService = AudioService()

    // =========================================================================
    // EventSink 引用（STT / NMT 结果推送用）
    // 由各自 StreamHandler 的 onListen / onCancel 管理
    // =========================================================================
    private var sttEventSink: EventChannel.EventSink? = null
    private var nmtEventSink: EventChannel.EventSink? = null

    // =========================================================================
    // configureFlutterEngine
    //
    // 来源：https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html
    // 工作手册禁止项 ❌7：省略 super.configureFlutterEngine() 会导致插件注册失败
    // =========================================================================
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {

        // 必须调用 super，否则 Flutter 插件系统不会初始化
        // 来源：GloTalk V3 工作手册 第十章 禁止项 ❌7
        super.configureFlutterEngine(flutterEngine)

        setupControlChannel(flutterEngine)
        setupAudioStreamChannel(flutterEngine)
        setupSttChannel(flutterEngine)
        setupNmtChannel(flutterEngine)
    }

    // =========================================================================
    // MethodChannel：tech.glotalk/control
    // 来源：GloTalk V3 工作手册 第七章 7.2
    // 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/MethodChannel.html
    // =========================================================================
    private fun setupControlChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONTROL_CHANNEL   // "tech.glotalk/control"
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "initModels" -> {
                    val srcLang = call.argument<String>("srcLang") ?: "en"
                    val tgtLang = call.argument<String>("tgtLang") ?: "zh"
                    // TODO：传递给 WhisperInference / OpusMTInference 初始化
                    android.util.Log.i("MainActivity", "initModels: $srcLang → $tgtLang")
                    result.success(true)
                }

                "startRecording" -> {
                    val started = audioService.startRecording()
                    if (started) {
                        result.success(true)
                    } else {
                        // AudioRecord 初始化失败（D1 / D2 检查未通过）
                        result.error(
                            "AUDIO_INIT_FAILED",
                            "AudioRecord 初始化失败，请检查麦克风权限或硬件支持",
                            null
                        )
                    }
                }

                "stopRecording" -> {
                    audioService.stopRecording()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    // =========================================================================
    // EventChannel：tech.glotalk/audio_stream — PCM 音频数据流
    //
    // 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/EventChannel.html
    // 来源：https://github.com/flutter/flutter/issues/34993（EventSink 线程规则）
    //
    // 职责：
    //   onListen → 将 EventSink 注入 AudioService，AudioService 内部已通过
    //              mainHandler 确保在主线程调用（D4 修正）
    //   onCancel → 将 AudioService.eventSink 置 null，停止推送
    // =========================================================================
    private fun setupAudioStreamChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUDIO_STREAM_CHANNEL  // "tech.glotalk/audio_stream"
        ).setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                // 将 EventSink 注入 AudioService
                // AudioService 内部通过 mainHandler.post {} 保证主线程调用（D4 修正）
                // 来源：https://github.com/flutter/flutter/issues/34993
                audioService.eventSink = events
                android.util.Log.i("MainActivity", "audio_stream：Flutter 已订阅，EventSink 已注入")
            }

            override fun onCancel(arguments: Any?) {
                // Flutter 取消订阅时，将 EventSink 置 null 停止推送
                audioService.eventSink = null
                android.util.Log.i("MainActivity", "audio_stream：Flutter 已取消订阅，EventSink 已置 null")
            }
        })
    }

    // =========================================================================
    // EventChannel：tech.glotalk/stt_result — STT 实时识别文本流
    // 来源：GloTalk V3 工作手册 第七章 7.2
    // 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/EventChannel.html
    // =========================================================================
    private fun setupSttChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STT_CHANNEL  // "tech.glotalk/stt_result"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sttEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                sttEventSink = null
            }
        })
    }

    // =========================================================================
    // EventChannel：tech.glotalk/nmt_result — NMT 翻译文本流
    // 来源：GloTalk V3 工作手册 第七章 7.2
    // 来源：https://api.flutter.dev/javadoc/io/flutter/plugin/common/EventChannel.html
    // =========================================================================
    private fun setupNmtChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NMT_CHANNEL  // "tech.glotalk/nmt_result"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                nmtEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                nmtEventSink = null
            }
        })
    }

    // =========================================================================
    // 公开方法：从 Pipeline（Whisper / OpusMT）推送结果到 Flutter
    //
    // 来源：GloTalk V3 工作手册 第七章 7.2
    // 规则：EventSink.success() 必须在主线程调用
    // 来源：https://github.com/flutter/flutter/issues/34993
    // 使用 runOnUiThread（Activity 内可用，等效于 Handler(Looper.getMainLooper()).post{}）
    // 来源：https://developer.android.com/reference/android/app/Activity#runOnUiThread(java.lang.Runnable)
    // =========================================================================

    /** 将 Whisper STT 识别结果推送至 Flutter stt_result 流 */
    fun pushSttResult(text: String) {
        runOnUiThread {
            sttEventSink?.success(text)
        }
    }

    /** 将 Opus-MT NMT 翻译结果推送至 Flutter nmt_result 流 */
    fun pushNmtResult(text: String) {
        runOnUiThread {
            nmtEventSink?.success(text)
        }
    }
}
