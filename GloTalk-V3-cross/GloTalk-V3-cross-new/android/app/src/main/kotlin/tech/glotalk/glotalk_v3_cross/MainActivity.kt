package tech.glotalk.glotalk_v3_cross

import ai.onnxruntime.OrtEnvironment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "tech.glotalk/inference"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ping" -> result.success("pong")
                    "testOnnxRuntime" -> {
                        try {
                            val env = OrtEnvironment.getEnvironment()
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