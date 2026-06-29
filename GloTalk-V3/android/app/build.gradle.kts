plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "tech.glotalk.glotalk_v3"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "tech.glotalk.glotalk_v3"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // OnnxRuntime Android — Maven Central，MIT 许可
    // 查证结论：必须用 implementation（不能用 runtimeOnly）
    // package 名 ai.onnxruntime（非 com.microsoft.onnxruntime）
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")
}
