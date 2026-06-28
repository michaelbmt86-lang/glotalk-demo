-keep class ai.onnxruntime.** { *; }
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keepclassmembers class * {
    native <methods>;
}
