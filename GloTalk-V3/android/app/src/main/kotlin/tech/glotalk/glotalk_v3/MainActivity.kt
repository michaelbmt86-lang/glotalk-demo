package tech.glotalk.glotalk_v3

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

// OnnxRuntime — package 是 ai.onnxruntime（非 com.microsoft.onnxruntime）
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.OnnxTensor

class MainActivity : FlutterActivity() {

    // OrtEnvironment 是 JVM 内唯一单例，无需手动 close()
    private val ortEnv: OrtEnvironment = OrtEnvironment.getEnvironment()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 规则 8：必须调用 super
        super.configureFlutterEngine(flutterEngine)

        // TODO: 在此注册 MethodChannel / EventChannel
        // MethodChannel 和 EventChannel 两端 channel 名称必须完全一致（规则 9）
    }

    override fun onDestroy() {
        // OrtSession 和 OnnxTensor 需要在此 close（规则 10）
        // ortEnv.close() ← 禁止：OrtEnvironment 的 close() 是 no-op，JVM shutdown hook 自动处理
        super.onDestroy()
    }
}
