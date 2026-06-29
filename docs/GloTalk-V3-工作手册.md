# GloTalk-V3 工作手册

> **版本：** V3.1 | **最后更新：** 2026-06-29 | **维护者：** GloTalk 开发团队  
> **GitHub：** `michaelbmt86-lang/glotalk-demo` → 子目录 `GloTalk-V3/`  
> **线上版本：** alibaba-v1（网页版）→ https://glotalk.tech/glotalk-al.html  
> **服务器：** 47.84.206.142（新加坡）| 域名 glotalk.tech | **到期：2026-07-09 必须续费**

---

## 第一章：项目背景与最高原则

### 1.1 项目定位

GloTalk 是一款**跨语言实时语音翻译 App**，设计目标是成为 Android 与 iOS 平台的纯本地、零网络依赖的实时口语翻译工具。

参照对象：[Apple Live Translation](https://support.apple.com/en-gb/guide/iphone/iph22b72984d/26/ios/26) 技术架构，以及 [RTranslator](https://github.com/niedev/RTranslator) 开源 Android 实时翻译 App（Meta NLLB + OpenAI Whisper，全部本地运行）。

### 1.2 最高原则（不可妥协）

| 编号 | 原则 | 说明 |
|------|------|------|
| P1 | **设备端完全离线** | 所有推理均在本机运行，无需联网，无需云端 API |
| P2 | **流式实时翻译** | 语音识别 → 翻译 → 合成，全链路流式，延迟最小化 |
| P3 | **全栈开源积木** | 每个节点均使用开源模型与库，可审计、可商用 |
| P4 | **动手前必查官方文档** | 严禁凭记忆猜 API 名称，任何代码改动必须先查证 |
| P5 | **从根部解决问题** | 遇到冲突不打局部补丁，从架构层彻底解决 |

---

## 第二章：技术架构（四节点图）

### 2.1 核心数据流

```
麦克风音频输入
      │
      ▼
┌─────────────────────────────────────────────┐
│  节点 1：VAD（语音活动检测）                 │
│  Silero VAD（ONNX，MIT）                    │
│  → 检测语音帧，过滤静音，触发识别             │
└─────────────┬───────────────────────────────┘
              │ 有效语音帧
              ▼
┌─────────────────────────────────────────────┐
│  节点 2：STT（语音转文字）                   │
│  Whisper ONNX int8（MIT）                   │
│  → 流式/分段识别，输出源语言文本             │
└─────────────┬───────────────────────────────┘
              │ 源语言文本
              ▼
┌─────────────────────────────────────────────┐
│  节点 3：NMT（神经机器翻译）                 │
│  Opus-MT（ONNX，Apache 2.0，可商用）         │
│  → 翻译为目标语言文本                        │
└─────────────┬───────────────────────────────┘
              │ 目标语言文本
              ▼
┌─────────────────────────────────────────────┐
│  节点 4：TTS（文字转语音）                   │
│  Android TextToSpeech API（系统自带）        │
│  → 合成目标语言语音，播放给用户              │
└─────────────────────────────────────────────┘
```

### 2.2 跨层通信架构

```
Flutter / Dart UI 层
    │ MethodChannel（单次调用：初始化、配置、控制）
    │ EventChannel（流式：实时识别结果、翻译结果推送）
    ▼
Kotlin / Android 原生层
    │ OnnxRuntime Java API
    ▼
ONNX 模型层（Whisper / Opus-MT / Silero VAD）
```

### 2.3 架构验证结果（2026-06-29）

在红米 Note 12（Android 13，arm64，8GB）上验证通过：

| 测试项 | 结果 |
|--------|------|
| Flutter → MethodChannel → Kotlin 通信 | ✅ pong |
| OnnxRuntime 1.23.2 加载 | ✅ OrtEnvironment OK |
| 崩溃 / 冲突 | ❌ 无 |

---

## 第三章：为什么放弃 sherpa_onnx / flutter_onnxruntime

### 3.1 放弃 sherpa_onnx

**原因：架构级不可解决的动态库版本冲突**

- `sherpa_onnx` 内部捆绑了 `libonnxruntime.so` **版本 1.17.1**
- 项目所需的 OnnxRuntime Java API 版本为 **1.23.2**
- 两个 `.so` 文件在同一 APK 内共存时，`OrtGetApiBase` 符号解析崩溃
- 属于 native symbol 层冲突，无法通过 ProGuard / namespace 等手段规避
- **结论：永久废弃，禁止在任何分支引入**

### 3.2 放弃 flutter_onnxruntime

**原因：同类 libonnxruntime.so 版本冲突**

- `flutter_onnxruntime` 捆绑 `libonnxruntime.so` **版本 1.22.0**
- 与 sherpa_onnx 的 1.17.1 或本项目的 1.23.2 均不兼容
- 运行时抛出 `UnsatisfiedLinkError: OrtGetApiBase`
- **结论：永久废弃，禁止在任何分支引入**

### 3.3 放弃 onnxruntime dart:ffi

**原因：同样自带 libonnxruntime.so**

- 通过 dart:ffi 调用的 onnxruntime 包也会捆绑自己的 `.so`
- 与 Java API 路径的 `.so` 冲突
- **结论：永久废弃，所有 ONNX 推理统一走 Kotlin → OnnxRuntime Java API**

### 3.4 唯一正确路线

```
OnnxRuntime Java API
com.microsoft.onnxruntime:onnxruntime-android:1.23.2
MIT 协议 | 单一版本 | 零冲突
```

---

## 第四章：技术栈（已查证版本）

### 4.1 Flutter / Dart 层

| 包名 | 版本 | 用途 | 协议 |
|------|------|------|------|
| `flutter` | SDK stable | UI 框架 | BSD |
| `permission_handler` | ^12.0.1 | 麦克风权限请求 | MIT |
| `path_provider` | ^2.1.5 | 获取本地模型路径 | BSD |

### 4.2 Android 原生层

| 库 | 版本 | 用途 | 协议 |
|----|------|------|------|
| `com.microsoft.onnxruntime:onnxruntime-android` | **1.23.2** | ONNX 模型推理 | MIT |
| `Android AudioRecord` | 系统 API | 麦克风采集 PCM | 系统 |
| `Android TextToSpeech` | 系统 API | TTS 语音合成 | 系统 |

### 4.3 ONNX 模型层

| 模型 | 格式 | 用途 | 协议 |
|------|------|------|------|
| Whisper（tiny/base/small int8） | ONNX int8 | STT 语音识别 | MIT |
| Opus-MT（opus-mt-\[src\]-\[tgt\]） | ONNX | NMT 机器翻译 | Apache 2.0 |
| Silero VAD v4 | ONNX | 语音活动检测 | MIT |

### 4.4 目标平台

- **Android**（主线，已验证）
- **iOS**（计划中，OnnxRuntime iOS 兼容）

---

## 第五章：麦克风采集方案（路线A：AudioRecord + EventChannel）

### 5.1 方案选型

| 方案 | 技术 | 状态 |
|------|------|------|
| **路线 A（采用）** | Android `AudioRecord` + `EventChannel` | ✅ 主线方案 |
| 路线 B（弃用） | `sherpa_onnx` 内置麦克风 | ❌ 冲突废弃 |

### 5.2 AudioRecord 初始化（Kotlin）

```kotlin
// android/app/src/main/kotlin/com/glotalk/app/AudioService.kt

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

class AudioService {
    companion object {
        // Whisper 要求 16kHz 单声道 PCM_16BIT
        const val SAMPLE_RATE = 16000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var audioRecord: AudioRecord? = null
    private var isRecording = false

    fun startRecording(onAudioData: (ShortArray) -> Unit) {
        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT
        )
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT,
            bufferSize
        )
        audioRecord?.startRecording()
        isRecording = true

        Thread {
            val buffer = ShortArray(bufferSize / 2)
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (read > 0) {
                    onAudioData(buffer.copyOf(read))
                }
            }
        }.start()
    }

    fun stopRecording() {
        isRecording = false
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
    }
}
```

### 5.3 EventChannel 推送音频数据到 Flutter

```kotlin
// MainActivity.kt 中注册 EventChannel

private val AUDIO_CHANNEL = "tech.glotalk/audio_stream"

private fun setupAudioEventChannel(flutterEngine: FlutterEngine) {
    EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
        .setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioService.startRecording { pcmData ->
                    // 在主线程回调 EventSink
                    Handler(Looper.getMainLooper()).post {
                        events?.success(pcmData.map { it.toInt() })
                    }
                }
            }
            override fun onCancel(arguments: Any?) {
                audioService.stopRecording()
            }
        })
}
```

### 5.4 Flutter Dart 订阅音频流

```dart
// lib/services/audio_service.dart

const _audioChannel = EventChannel('tech.glotalk/audio_stream');

Stream<List<int>> get audioStream =>
    _audioChannel.receiveBroadcastStream().cast<List<int>>();
```

### 5.5 AudioRecord 权限配置

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

```dart
// Flutter 层请求权限
final status = await Permission.microphone.request();
if (!status.isGranted) {
  // 处理权限拒绝
}
```

---

## 第六章：OnnxRuntime Java API 正确写法

### 6.1 正确 API 序列（必须遵守）

```
OrtEnvironment.getEnvironment()           ← 获取全局环境（单例）
    → env.createSession(path, options)    ← 创建推理会话
    → OnnxTensor.createTensor(env, data, shape)  ← 创建输入张量
    → session.run(inputs)                 ← 执行推理
    → result[outputIndex].value           ← 读取输出
    → tensor.close()                      ← 必须 close 张量
    → session.close()                     ← 必须 close 会话（推理后）
```

### 6.2 Whisper STT 推理示例（Kotlin）

```kotlin
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession

class WhisperInference(private val modelPath: String) {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null

    fun loadModel() {
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
            // 可选：启用 NNAPI 加速
            // addNnapi()
        }
        session = env.createSession(modelPath, options)
    }

    fun transcribe(audioFeatures: FloatArray, shape: LongArray): String {
        val inputTensor = OnnxTensor.createTensor(env, audioFeatures, shape)
        var result = ""
        try {
            val inputs = mapOf("input_features" to inputTensor)
            val output = session!!.run(inputs)
            val logits = output[0].value as Array<Array<FloatArray>>
            // 解码 token → 文本（需配合 tokenizer）
            result = decodeTokens(logits)
            output.close()
        } finally {
            inputTensor.close()  // ← 必须 close，防止 native 内存泄漏
        }
        return result
    }

    fun close() {
        session?.close()
        session = null
    }

    private fun decodeTokens(logits: Array<Array<FloatArray>>): String {
        // 实现 greedy decode / beam search
        return ""
    }
}
```

### 6.3 Opus-MT 翻译推理示例（Kotlin）

```kotlin
class OpusMTInference(private val modelPath: String) {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null

    fun loadModel() {
        session = env.createSession(modelPath, OrtSession.SessionOptions())
    }

    fun translate(inputIds: LongArray, attentionMask: LongArray): LongArray {
        val batchSize = 1L
        val seqLen = inputIds.size.toLong()

        val inputTensor = OnnxTensor.createTensor(
            env, inputIds, longArrayOf(batchSize, seqLen)
        )
        val maskTensor = OnnxTensor.createTensor(
            env, attentionMask, longArrayOf(batchSize, seqLen)
        )
        var outputIds = longArrayOf()
        try {
            val inputs = mapOf(
                "input_ids" to inputTensor,
                "attention_mask" to maskTensor
            )
            val output = session!!.run(inputs)
            outputIds = (output[0].value as Array<LongArray>)[0]
            output.close()
        } finally {
            inputTensor.close()   // ← 必须 close
            maskTensor.close()    // ← 必须 close
        }
        return outputIds
    }

    fun close() {
        session?.close()
        session = null
    }
}
```

### 6.4 Silero VAD 推理示例（Kotlin）

```kotlin
class SileroVAD(private val modelPath: String) {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null

    fun loadModel() {
        session = env.createSession(modelPath, OrtSession.SessionOptions())
    }

    // 返回 0.0~1.0 的语音概率
    fun isSpeech(pcmFrame: FloatArray): Float {
        val shape = longArrayOf(1, pcmFrame.size.toLong())
        val inputTensor = OnnxTensor.createTensor(env, pcmFrame, shape)
        var probability = 0f
        try {
            val output = session!!.run(mapOf("input" to inputTensor))
            probability = ((output[0].value as Array<FloatArray>)[0][0])
            output.close()
        } finally {
            inputTensor.close()
        }
        return probability
    }

    fun close() {
        session?.close()
        session = null
    }
}
```

---

## 第七章：MethodChannel / EventChannel 正确写法

> **铁律：两端 channel 名称字符串必须完全一致，大小写敏感。**

### 7.1 Channel 名称常量表

| Channel | 名称字符串 | 类型 | 用途 |
|---------|-----------|------|------|
| 控制通道 | `tech.glotalk/control` | MethodChannel | 初始化、开始/停止录音 |
| 识别结果 | `tech.glotalk/stt_result` | EventChannel | STT 实时文本流 |
| 翻译结果 | `tech.glotalk/nmt_result` | EventChannel | NMT 翻译文本流 |
| 音频流 | `tech.glotalk/audio_stream` | EventChannel | PCM 音频数据流 |

### 7.2 Kotlin 侧（MainActivity.kt）

```kotlin
// android/app/src/main/kotlin/com/glotalk/app/MainActivity.kt

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // Channel 名称常量（与 Dart 侧完全一致）
    private val CONTROL_CHANNEL = "tech.glotalk/control"
    private val STT_CHANNEL     = "tech.glotalk/stt_result"
    private val NMT_CHANNEL     = "tech.glotalk/nmt_result"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)  // ← 必须调用 super

        // MethodChannel：处理单次调用
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initModels" -> {
                        val srcLang = call.argument<String>("srcLang") ?: "en"
                        val tgtLang = call.argument<String>("tgtLang") ?: "zh"
                        initModels(srcLang, tgtLang)
                        result.success(true)
                    }
                    "startRecording" -> {
                        startPipeline()
                        result.success(true)
                    }
                    "stopRecording" -> {
                        stopPipeline()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // EventChannel：STT 结果流
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STT_CHANNEL)
            .setStreamHandler(sttStreamHandler)

        // EventChannel：NMT 结果流
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NMT_CHANNEL)
            .setStreamHandler(nmtStreamHandler)
    }

    private val sttStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sttEventSink = events
        }
        override fun onCancel(arguments: Any?) {
            sttEventSink = null
        }
    }

    private val nmtStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            nmtEventSink = events
        }
        override fun onCancel(arguments: Any?) {
            nmtEventSink = null
        }
    }

    private var sttEventSink: EventChannel.EventSink? = null
    private var nmtEventSink: EventChannel.EventSink? = null

    // 推送识别结果到 Flutter
    fun pushSttResult(text: String) {
        runOnUiThread { sttEventSink?.success(text) }
    }

    // 推送翻译结果到 Flutter
    fun pushNmtResult(text: String) {
        runOnUiThread { nmtEventSink?.success(text) }
    }
}
```

### 7.3 Dart 侧（Flutter）

```dart
// lib/services/translation_service.dart

import 'package:flutter/services.dart';

class TranslationService {
  static const _controlChannel = MethodChannel('tech.glotalk/control');
  static const _sttChannel = EventChannel('tech.glotalk/stt_result');
  static const _nmtChannel = EventChannel('tech.glotalk/nmt_result');

  // 初始化模型
  Future<void> initModels({
    required String srcLang,
    required String tgtLang,
  }) async {
    await _controlChannel.invokeMethod('initModels', {
      'srcLang': srcLang,
      'tgtLang': tgtLang,
    });
  }

  // 开始录音
  Future<void> startRecording() async {
    await _controlChannel.invokeMethod('startRecording');
  }

  // 停止录音
  Future<void> stopRecording() async {
    await _controlChannel.invokeMethod('stopRecording');
  }

  // 订阅 STT 识别文本流
  Stream<String> get sttStream =>
      _sttChannel.receiveBroadcastStream().cast<String>();

  // 订阅 NMT 翻译文本流
  Stream<String> get nmtStream =>
      _nmtChannel.receiveBroadcastStream().cast<String>();
}
```

### 7.4 main.dart 必须格式

```dart
// lib/main.dart

import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();  // ← 必须，async main 前置
  runApp(const GloTalkApp());
}
```

---

## 第八章：模型文件清单（授权协议）

### 8.1 合规模型（可商用）

| 模型 | 版本/规格 | 格式 | 授权协议 | 商用 | 文件名示例 |
|------|-----------|------|----------|------|-----------|
| **Whisper** | tiny int8 | ONNX | MIT | ✅ | `whisper-tiny-int8.onnx` |
| **Whisper** | base int8 | ONNX | MIT | ✅ | `whisper-base-int8.onnx` |
| **Whisper** | small int8 | ONNX | MIT | ✅ | `whisper-small-int8.onnx` |
| **Opus-MT** | en-zh | ONNX | Apache 2.0 | ✅ | `opus-mt-en-zh.onnx` |
| **Opus-MT** | zh-en | ONNX | Apache 2.0 | ✅ | `opus-mt-zh-en.onnx` |
| **Opus-MT** | en-ja | ONNX | Apache 2.0 | ✅ | `opus-mt-en-ja.onnx` |
| **Silero VAD** | v4 | ONNX | MIT | ✅ | `silero_vad.onnx` |

### 8.2 禁用模型

| 模型 | 原因 | 替代方案 |
|------|------|---------|
| **Meta NLLB** 系列 | CC-BY-NC 4.0，**禁止商用** | Opus-MT（Apache 2.0）|
| **NLLB-200** | 同上 | Opus-MT |

### 8.3 模型文件部署路径（Android）

```
android/app/src/main/assets/models/
├── silero_vad.onnx          # VAD 模型（约 2MB）
├── whisper-tiny-int8.onnx   # STT 模型（约 40MB）
├── opus-mt-en-zh.onnx       # 英→中翻译（约 300MB）
└── opus-mt-zh-en.onnx       # 中→英翻译（约 300MB）
```

> **注意：** 模型文件体积较大，建议通过首次启动下载或分包方式处理，避免 APK 超过 Google Play 100MB 限制。

---

## 第九章：Android 必须配置文件

### 9.1 AndroidManifest.xml

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- 必须权限 -->
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.INTERNET"
        android:required="false"/>  <!-- 仅首次下载模型时需要，离线运行时可选 -->

    <application
        android:label="GloTalk"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:usesCleartextTraffic="false">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
```

### 9.2 build.gradle（app 级）

```groovy
// android/app/build.gradle

android {
    compileSdk 34
    defaultConfig {
        applicationId "com.glotalk.app"
        minSdk 24          // OnnxRuntime Android 要求 minSdk ≥ 21
        targetSdk 34
        versionCode 1
        versionName "3.0.0"

        // 支持的 ABI（减小包体积，可按需调整）
        ndk {
            abiFilters 'arm64-v8a', 'x86_64'
        }
    }

    // 大模型文件不压缩（ONNX 已压缩，再压缩无意义且耗时）
    aaptOptions {
        noCompress "onnx"
    }

    buildTypes {
        release {
            minifyEnabled true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'),
                         'proguard-rules.pro'
        }
    }
}

dependencies {
    // OnnxRuntime Java API（唯一指定版本，不可随意升降）
    implementation 'com.microsoft.onnxruntime:onnxruntime-android:1.23.2'

    // Flutter 自动添加的依赖
    implementation "org.jetbrains.kotlin:kotlin-stdlib-jdk8:$kotlin_version"
}
```

### 9.3 proguard-rules.pro

```pro
# android/app/proguard-rules.pro

# 保留 OnnxRuntime 所有类（防止混淆导致 native 方法找不到）
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }

# 保留 Flutter 通信类
-keep class io.flutter.** { *; }
-keep class io.flutter.plugin.** { *; }
```

### 9.4 pubspec.yaml（Flutter 层）

```yaml
# pubspec.yaml

name: glotalk_v3
description: GloTalk V3 - Real-time Local Voice Translation

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.10.0'

dependencies:
  flutter:
    sdk: flutter
  permission_handler: ^12.0.1   # 麦克风权限
  path_provider: ^2.1.5         # 本地路径（模型文件）

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/models/           # 模型文件目录（小文件可放这里）
```

---

## 第十章：禁止事项清单

### 10.1 绝对禁止（架构红线）

| 编号 | 禁止项 | 原因 |
|------|--------|------|
| ❌ 1 | 引入 `sherpa_onnx` | 捆绑 libonnxruntime.so 1.17.1，OrtGetApiBase 崩溃 |
| ❌ 2 | 引入 `flutter_onnxruntime` | 捆绑 libonnxruntime.so 1.22.0，版本冲突 |
| ❌ 3 | 引入 `onnxruntime` dart:ffi 包 | 自带 libonnxruntime.so，与 Java API 冲突 |
| ❌ 4 | 使用 NLLB 任意版本模型 | CC-BY-NC 4.0，禁止商用 |
| ❌ 5 | 凭记忆猜 API 名称写代码 | 必须查官方文档后再动手 |
| ❌ 6 | 打局部补丁掩盖根本问题 | 从根部解决，不留技术债 |
| ❌ 7 | 省略 `super.configureFlutterEngine()` | MainActivity 插件注册失败 |
| ❌ 8 | main() 不加 `async` + `ensureInitialized()` | 平台通道初始化时序错误 |
| ❌ 9 | MethodChannel/EventChannel 两端名称不一致 | 通信失败，静默无报错 |
| ❌ 10 | 推理后不 close OnnxTensor | Native 内存泄漏，OOM 崩溃 |
| ❌ 11 | 推理后不 close OrtSession | 内存泄漏 |
| ❌ 12 | 在非主线程调用 EventSink | IllegalStateException 崩溃 |

### 10.2 代码审核 12 条清单

在提交代码前，逐项确认：

- [ ] 1. `main()` 是 `async` 且第一行是 `WidgetsFlutterBinding.ensureInitialized()`
- [ ] 2. `MainActivity.kt` 有 `super.configureFlutterEngine(flutterEngine)`
- [ ] 3. 所有 MethodChannel 两端名称字符串完全一致
- [ ] 4. 所有 EventChannel 两端名称字符串完全一致
- [ ] 5. `build.gradle` 中 OnnxRuntime 版本为 `1.23.2`，未引入其他 ort 包
- [ ] 6. 所有 ONNX 推理后有 `tensor.close()`（在 finally 块中）
- [ ] 7. 所有 `OrtSession` 使用完后有 `session.close()`
- [ ] 8. 未引入 `sherpa_onnx`、`flutter_onnxruntime`、ffi ort 包
- [ ] 9. 未使用 NLLB 相关模型（文件名、依赖均检查）
- [ ] 10. `EventSink.success()` 在 `runOnUiThread {}` 或主线程中调用
- [ ] 11. `AndroidManifest.xml` 有 `RECORD_AUDIO` 权限
- [ ] 12. `build.gradle` 有 `aaptOptions { noCompress "onnx" }`

---

## 第十一章：三个智能体工作流程

### 11.1 智能体定义

```
智能体 A：GloTalk 文档查证
    职责：查证官方文档，核实 API 名称、版本、参数
    产出：文档查证报告（纯文字，不含代码）
    规则：不写任何代码，只查证、只报告

智能体 B：GloTalk 代码编辑
    职责：按查证报告写代码
    产出：完整代码文件（Kotlin / Dart）
    规则：只按 A 的报告写，不自行查证，不猜 API

智能体 C：GloTalk 代码审核
    职责：逐项对照 10.2 中 12 条清单审核
    产出：审核报告（通过 / 不通过 + 具体问题）
    规则：逐条过清单，有任何不通过必须退回 B 修改
```

### 11.2 标准工作流程

```
需求 / Bug
    │
    ▼
┌─────────────────────┐
│  智能体 A            │
│  文档查证            │
│  → 查官方文档        │
│  → 输出查证报告      │
└──────────┬──────────┘
           │ 查证报告
           ▼
┌─────────────────────┐
│  智能体 B            │
│  代码编辑            │
│  → 按报告写代码      │
│  → 输出代码文件      │
└──────────┬──────────┘
           │ 代码文件
           ▼
┌─────────────────────┐
│  智能体 C            │
│  代码审核            │
│  → 逐项过 12 条清单  │
│  → 通过 / 不通过     │
└──────────┬──────────┘
           │ 通过
           ▼
    上传 GitHub
    michaelbmt86-lang/glotalk-demo
```

### 11.3 退回规则

- 审核不通过 → 智能体 C 出具不通过报告，指出具体条目
- 退回智能体 B 修改，不得跳过重新审核
- 同一问题退回超过 2 次 → 升级到智能体 A 重新查证文档

---

## 第十二章：GitHub 目录结构

```
michaelbmt86-lang/glotalk-demo/
│
├── README.md                          # 项目总览
│
├── GloTalk-V3/                  # 主线项目目录
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart ✅ 已验证          # 入口（async + ensureInitialized）
│   │   ├── app.dart                   # 根 Widget
│   │   ├── services/
│   │   │   ├── translation_service.dart   # MethodChannel/EventChannel Dart 侧
│   │   │   └── audio_service.dart         # 音频流订阅（待实现）
│   │   ├── screens/
│   │   │   └── home_screen.dart           # 主界面
│   │   └── widgets/
│   │       ├── transcript_view.dart       # 识别文本显示
│   │       └── translation_view.dart      # 翻译文本显示
│   │
│   ├── test/
│   │   └── widget_test.dart ✅ 已验证
│   │
│   ├── android/
│   │   ├── app/
│   │   │   ├── build.gradle.kts ✅ 已验证   # onnxruntime-android:1.23.2
│   │   │   ├── proguard-rules.pro
│   │   │   └── src/main/
│   │   │       ├── AndroidManifest.xml    # RECORD_AUDIO 权限
│   │   │       ├── assets/models/         # ONNX 模型文件
│   │   │       │   ├── silero_vad.onnx
│   │   │       │   ├── whisper-tiny-int8.onnx
│   │   │       │   └── opus-mt-en-zh.onnx
│   │   │       └── kotlin/tech/glotalk/glotalk_v3/
│   │   │           ├── MainActivity.kt ✅ 已验证  # super.configureFlutterEngine ✓
│   │   │           ├── AudioService.kt    # 待实现：Android AudioRecord 麦克风采集
│   │   │           ├── SileroVAD.kt       # 待实现：Silero VAD ONNX 推理
│   │   │           ├── WhisperInference.kt  # 待实现：Whisper STT ONNX 推理
│   │   │           └── OpusMTInference.kt   # 待实现：Opus-MT 翻译 ONNX 推理
│   │   └── build.gradle                  # 项目级 gradle
│   │
│   └── ios/
│       ├── Runner/
│       │   └── AppDelegate.swift
│       └── Podfile
│
├── docs/
│   ├── GloTalk-V3-工作手册.md            # 本文档
│   ├── architecture.md                   # 架构详解
│   └── model-licenses.md                 # 模型授权清单
│
└── alibaba-v1/                           # 线上网页版
    └── glotalk-al.html
```

---

## 第十三章：Codemagic 配置

### 13.1 codemagic.yaml 基础配置

```yaml
# codemagic.yaml（放置于 GloTalk-V3/ 根目录）

workflows:
  glotalk-android-release:
    name: GloTalk V3 Android Release
    max_build_duration: 60   # 分钟

    environment:
      flutter: stable
      java: 17               # OnnxRuntime 1.23.2 需要 Java 17+
      android_signing:
        - glotalk_keystore   # 在 Codemagic 控制台配置
      vars:
        PACKAGE_NAME: "com.glotalk.app"

    scripts:
      - name: 检查 Flutter 版本
        script: flutter --version

      - name: 获取依赖
        script: |
          cd GloTalk-V3
          flutter pub get

      - name: 运行单元测试
        script: |
          cd GloTalk-V3
          flutter test

      - name: 构建 Android Release APK
        script: |
          cd GloTalk-V3
          flutter build apk \
            --release \
            --split-per-abi \
            --obfuscate \
            --split-debug-info=build/debug-info

      - name: 构建 Android App Bundle（用于 Play Store）
        script: |
          cd GloTalk-V3
          flutter build appbundle \
            --release \
            --obfuscate \
            --split-debug-info=build/debug-info

    artifacts:
      - GloTalk-V3/build/app/outputs/flutter-apk/*.apk
      - GloTalk-V3/build/app/outputs/bundle/release/*.aab
      - GloTalk-V3/build/debug-info/**

    publishing:
      email:
        recipients:
          - dev@glotalk.tech
        notify:
          success: true
          failure: true
```

### 13.2 iOS 构建配置（参考）

```yaml
  glotalk-ios-release:
    name: GloTalk V3 iOS Release
    max_build_duration: 90

    environment:
      flutter: stable
      xcode: latest
      cocoapods: default
      ios_signing:
        distribution_type: app_store
        bundle_identifier: com.glotalk.app

    scripts:
      - name: 获取依赖
        script: |
          cd GloTalk-V3
          flutter pub get

      - name: Pod 安装
        script: |
          cd GloTalk-V3/ios
          pod install

      - name: 构建 iOS
        script: |
          cd GloTalk-V3
          flutter build ipa --release

    artifacts:
      - GloTalk-V3/build/ios/ipa/*.ipa
```

### 13.3 Codemagic 环境变量配置

在 Codemagic 控制台 → App Settings → Environment variables 中配置：

| 变量名 | 说明 | 是否加密 |
|--------|------|---------|
| `CM_KEYSTORE` | Android 签名 keystore（base64） | ✅ |
| `CM_KEYSTORE_PASSWORD` | Keystore 密码 | ✅ |
| `CM_KEY_ALIAS` | Key alias | ✅ |
| `CM_KEY_PASSWORD` | Key 密码 | ✅ |

---

## 附录 A：常见错误速查表

| 错误信息 | 原因 | 解决方案 |
|----------|------|---------|
| `UnsatisfiedLinkError: OrtGetApiBase` | libonnxruntime.so 版本冲突 | 检查是否混入 sherpa_onnx/flutter_onnxruntime |
| `MissingPluginException` | MethodChannel 名称不一致 | 对齐 Dart 和 Kotlin 两端字符串 |
| `IllegalStateException: Reply already submitted` | EventSink 在非主线程调用 | 包裹 `runOnUiThread {}` |
| `OOM / Native heap` | OnnxTensor 未 close | 在 finally 块中强制 close |
| `FileNotFoundException: .onnx` | 模型路径错误 | 确认 assets 路径，用 path_provider 获取 |
| `PermissionDeniedException: RECORD_AUDIO` | 未申请麦克风权限 | permission_handler 动态申请 |

---

## 附录 B：版本历史

| 版本 | 日期 | 变更摘要 |
|------|------|---------|
| V1.0 | 2024 | 初版，基于 sherpa_onnx + NLLB |
| V2.0 | 2025 | 尝试 flutter_onnxruntime，遭遇冲突 |
| **V3.0** | **2026-06** | **新架构：OnnxRuntime Java API 1.23.2 + Opus-MT，彻底解决冲突** |
| **V3.1** | **2026-06-29** | **架构验证完成：Flutter→MethodChannel→Kotlin→OnnxRuntime 1.23.2 全链路在红米Note12验证通过，pong✅ OrtEnvironment✅** |

---

*本文档由 GloTalk 开发团队维护。任何架构变更须先更新本文档，再修改代码。*
