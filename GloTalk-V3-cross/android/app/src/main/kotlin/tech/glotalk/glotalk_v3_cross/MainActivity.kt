package tech.glotalk.glotalk_v3_cross

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

// 来源：https://docs.flutter.dev/platform-integration/platform-channels
class MainActivity : FlutterActivity() {

    private val CHANNEL = "tech.glotalk/inference"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ping" -> {
                        // 验证 MethodChannel 通信是否正常
                        result.success("pong")
                    }
                    "testOnnxRuntime" -> {
                        // 验证 OnnxRuntime 是否正确加载
                        try {
                            val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
                            result.success("OnnxRuntime OK: ${env.javaClass.simpleName}")
                        } catch (e: Exception) {
                            result.error("ORT_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
