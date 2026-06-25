# android/app/proguard-rules.pro
#
# GloTalk V3 混淆规则
# 参考来源：
#   1. sherpa-onnx 官方 Android AAR 构建脚本 & JNI 绑定约定
#      https://github.com/k2-fsa/sherpa-onnx/tree/master/android
#   2. flutter_onnxruntime >= 1.5.1 官方 README（Google Play 16KB 兼容）
#      https://pub.dev/packages/flutter_onnxruntime
#   3. Microsoft ONNX Runtime Android 官方文档
#      https://onnxruntime.ai/docs/get-started/with-java.html
#   4. LiveKit Android SDK 官方 ProGuard 规则
#      https://github.com/livekit/client-sdk-android
#   5. Flutter 官方 Android 混淆指南
#      https://flutter.dev/to/obfuscating-dart-code

# ─────────────────────────────────────────────────────────────
# 1. sherpa-onnx JNI：保留所有 JNI 调用点（k2-fsa 官方约定）
# ─────────────────────────────────────────────────────────────
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keepclassmembers class com.k2fsa.sherpa.onnx.** { *; }

# JNI 本地方法必须保留方法名（R8 默认会重命名，导致 UnsatisfiedLinkError）
-keepclasseswithmembernames class * {
    native <methods>;
}

# ─────────────────────────────────────────────────────────────
# 2. ONNX Runtime：microsoft 官方 ProGuard 规则
#    来源：com.microsoft.onnxruntime:onnxruntime-android gradle 文档
# ─────────────────────────────────────────────────────────────
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }

# ONNX Runtime 内部使用反射访问的 EP（Execution Provider）类
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes EnclosingMethod

# ─────────────────────────────────────────────────────────────
# 3. flutter_onnxruntime 原生桥接层（masic.ai，MIT）
#    flutter_onnxruntime >= 1.5.1 使用 Gradle 依赖而非手动 .so
#    但 Flutter Method Channel 名称仍需保留
# ─────────────────────────────────────────────────────────────
-keep class ai.masic.** { *; }
-keepclassmembers class ai.masic.** { *; }

# ─────────────────────────────────────────────────────────────
# 4. LiveKit Android SDK
#    来源：livekit/client-sdk-android 官方 README
# ─────────────────────────────────────────────────────────────
-keep class io.livekit.** { *; }
-keepclassmembers class io.livekit.** { *; }

# WebRTC 底层 JNI（LiveKit 依赖）
-keep class org.webrtc.** { *; }
-keepclassmembers class org.webrtc.** { *; }
-keepclasseswithmembernames class org.webrtc.** {
    native <methods>;
}

# ─────────────────────────────────────────────────────────────
# 5. Flutter / Dart 反射支持
#    Flutter 官方 Android 混淆指南要求
# ─────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keepclassmembers class io.flutter.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }

# Flutter Method Channel 传参（Map / List 序列化通过反射）
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# ─────────────────────────────────────────────────────────────
# 6. Android 系统组件（Activity / Service / BroadcastReceiver）
#    保证 LiveKit 前台服务（FOREGROUND_SERVICE）不被混淆
# ─────────────────────────────────────────────────────────────
-keep public class * extends android.app.Activity
-keep public class * extends android.app.Service
-keep public class * extends android.content.BroadcastReceiver
-keep public class * extends android.content.ContentProvider

# ─────────────────────────────────────────────────────────────
# 7. Kotlin 协程（LiveKit 内部大量使用）
# ─────────────────────────────────────────────────────────────
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}

# ─────────────────────────────────────────────────────────────
# 8. OkHttp（HTTP 客户端，LiveKit 信令依赖）
# ─────────────────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ─────────────────────────────────────────────────────────────
# 9. 抑制无害的警告（第三方库内部引用可选 API）
# ─────────────────────────────────────────────────────────────
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# ─────────────────────────────────────────────────────────────
# 10. 调试阶段：保留行号，方便崩溃报告定位
#     发布 release 时可以删除这两行以进一步缩小包体
# ─────────────────────────────────────────────────────────────
-keepattributes LineNumberTable
-keepattributes SourceFile
