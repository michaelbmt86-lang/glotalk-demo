// GloTalk-V3/lib/main.dart
// 智能体 B 代码编辑 | 依据：查证报告 A-005 | 任务：B-005
// 上一版本：B-003（测试1-7 全部保持不变，本次仅新增下载区域）

// Flutter SDK — https://api.flutter.dev/flutter/material/material-library.html
import 'package:flutter/material.dart';
// Platform channels — https://docs.flutter.dev/platform-integration/platform-channels
import 'package:flutter/services.dart';
// StreamSubscription — https://api.dart.dev/stable/dart-async/StreamSubscription-class.html
import 'dart:async';
// dart:io — File.exists()，检测模型文件是否已存在
// 来源：https://api.dart.dev/stable/dart-io/File-class.html
// 查证报告 A-005 §12.3（步骤3：_checkModelsExist）
import 'dart:io';
// permission_handler — https://pub.dev/packages/permission_handler
import 'package:permission_handler/permission_handler.dart';
// path_provider — getApplicationDocumentsDirectory()
// 来源：https://pub.dev/documentation/path_provider/latest/path_provider/getApplicationDocumentsDirectory.html
// 查证报告 A-005 §3.2：对应 Android filesDir 区域，不需要存储权限
import 'package:path_provider/path_provider.dart';
// dio — 用于模型文件 HTTP 下载，提供 onReceiveProgress 进度回调
// 来源：https://pub.dev/documentation/dio/latest/dio/Dio-class.html
// 查证报告 A-005 §六 & §12.3
import 'package:dio/dio.dart';

// ─────────────────────────────────────────────────────────────────────────────
// main()
// 铁律：必须 async，第一行必须 WidgetsFlutterBinding.ensureInitialized()
// 来源：https://docs.flutter.dev/platform-integration/platform-channels#step-2-create-the-flutter-platform-client
// 查证报告 A-003 第六章 §6.1
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  // ensureInitialized() — 必须在 async main 中 runApp 之前调用
  // 来源：https://api.flutter.dev/flutter/widgets/WidgetsFlutterBinding/ensureInitialized.html
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GloTalkApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel 常量（与 MainActivity.kt 完全一致，查证报告 A-003 第四章）
// 铁律：字符串完全一致，大小写敏感
// 来源：https://docs.flutter.dev/platform-integration/platform-channels
// ─────────────────────────────────────────────────────────────────────────────

// C1 — MethodChannel：ping、testOnnxRuntime
const _inferenceChannel = MethodChannel('tech.glotalk/inference');

// C2 — MethodChannel：initModels、startRecording、stopRecording、speakText
const _controlChannel = MethodChannel('tech.glotalk/control');

// C3 — EventChannel：PCM List<int> 音频帧流
const _audioStreamChannel = EventChannel('tech.glotalk/audio_stream');

// C4 — EventChannel：STT 文字流 + VAD 前缀标记
const _sttResultChannel = EventChannel('tech.glotalk/stt_result');

// C5 — EventChannel：NMT 翻译文字流
const _nmtResultChannel = EventChannel('tech.glotalk/nmt_result');

// ─────────────────────────────────────────────────────────────────────────────
// 模型文件下载清单（任务 B-005）
// 来源：查证报告 A-005 §二（需要下载的模型文件清单）
// hf-mirror.com 为 HuggingFace 国内镜像站，避免大陆网络问题
// ─────────────────────────────────────────────────────────────────────────────

// 每个条目：{ 'name': 本地文件名, 'url': 下载 URL }
// 来源：任务 B-005 需求 § _downloadModels 文件清单
const List<Map<String, String>> _modelFiles = [
  {
    'name': 'silero_vad.onnx',
    // 来源：https://hf-mirror.com/onnx-community/silero-vad/resolve/main/onnx/model.onnx
    // 节点1 VAD 模型，约 2MB
    'url': 'https://hf-mirror.com/onnx-community/silero-vad/resolve/main/onnx/model.onnx',
  },
  {
    'name': 'whisper_encoder_int8.onnx',
    // 来源：https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/encoder_model_int8.onnx
    // 节点2 STT Whisper small 编码器 int8，约 61MB
    'url': 'https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/encoder_model_int8.onnx',
  },
  {
    'name': 'whisper_decoder_int8.onnx',
    // 来源：https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/decoder_model_merged_int8.onnx
    // 节点2 STT Whisper small 解码器 int8 merged，约 184MB
    'url': 'https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/decoder_model_merged_int8.onnx',
  },
  {
    'name': 'opus_encoder_int8.onnx',
    // 来源：https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/onnx/encoder_model_int8.onnx
    // 节点3 NMT Opus-MT 编码器 int8，约 53MB
    'url': 'https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/onnx/encoder_model_int8.onnx',
  },
  {
    'name': 'opus_decoder_int8.onnx',
    // 来源：https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/onnx/decoder_model_int8.onnx
    // 节点3 NMT Opus-MT 解码器 int8，约 193MB
    'url': 'https://hf-mirror.com/onnx-community/opus-mt-zh-en/resolve/main/onnx/decoder_model_int8.onnx',
  },
  {
    'name': 'source.spm',
    // 来源：https://hf-mirror.com/Helsinki-NLP/opus-mt-zh-en/resolve/main/source.spm
    // 节点3 SentencePiece 源语言（中文）分词模型，约 4MB
    'url': 'https://hf-mirror.com/Helsinki-NLP/opus-mt-zh-en/resolve/main/source.spm',
  },
  {
    'name': 'target.spm',
    // 来源：https://hf-mirror.com/Helsinki-NLP/opus-mt-zh-en/resolve/main/target.spm
    // 节点3 SentencePiece 目标语言（英文）分词模型，约 4MB
    'url': 'https://hf-mirror.com/Helsinki-NLP/opus-mt-zh-en/resolve/main/target.spm',
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// GloTalkApp — 根 Widget
// ─────────────────────────────────────────────────────────────────────────────
class GloTalkApp extends StatelessWidget {
  const GloTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GloTalk V3 测试台',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const GloTalkTestPage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GloTalkTestPage — StatefulWidget，管理七个测试区块的状态
// 查证报告 A-003 第六章 §6.1
// ─────────────────────────────────────────────────────────────────────────────
class GloTalkTestPage extends StatefulWidget {
  const GloTalkTestPage({super.key});

  @override
  State<GloTalkTestPage> createState() => _GloTalkTestPageState();
}

class _GloTalkTestPageState extends State<GloTalkTestPage> {

  // ═══════════════════════════════════════════════════════════════════════════
  // 【B-005 新增】模型下载区域 — 状态变量
  // 来源：查证报告 A-005 §12.3（步骤2：状态变量）
  // ═══════════════════════════════════════════════════════════════════════════

  // 各文件下载进度 0.0~1.0；key = 文件名（'name' 字段），value = 进度值
  // 来源：dio onReceiveProgress(int received, int total) → received/total
  // 查证报告 A-005 §6.1（onReceiveProgress 回调签名）
  Map<String, double> _downloadProgress = {};

  // 是否正在下载中（防止重复点击）
  // 来源：查证报告 A-005 §12.3（步骤2）
  bool _isDownloading = false;

  // 是否全部模型文件已就绪（下载完成或文件已存在）
  // 来源：查证报告 A-005 §12.3（步骤3 & 步骤4）
  bool _modelsReady = false;

  // 下载错误信息（空字符串表示无错误）
  String _downloadError = '';

  // ─── 测试1：ping/pong 状态变量（查证报告 A-003 §6.2 测试1）
  String _pingResult = '等待测试...';

  // ─── 测试2：OnnxRuntime 状态变量（查证报告 A-003 §6.2 测试2）
  String _onnxResult = '等待测试...';

  // ─── 测试3：PCM 采集状态变量（查证报告 A-003 §6.2 测试3）
  int _totalPcmSamples = 0;
  bool _isRecordingAudio = false;

  // ─── 测试4：VAD 状态变量（查证报告 A-003 §6.2 测试4）
  String _vadStatus = '未开始';

  // ─── 测试5：STT 识别结果（查证报告 A-003 §6.2 测试5）
  String _sttText = '等待识别...';

  // ─── 测试6：NMT 翻译结果（查证报告 A-003 §6.2 测试6）
  String _nmtText = '等待翻译...';

  // ─── StreamSubscription 生命周期管理（查证报告 A-003 第七章）
  // 来源：https://api.dart.dev/stable/dart-async/StreamSubscription-class.html
  StreamSubscription<List<int>>? _audioSubscription;   // C3 音频流订阅
  StreamSubscription<String>? _sttSubscription;        // C4 STT 结果订阅
  StreamSubscription<String>? _nmtSubscription;        // C5 NMT 结果订阅

  // ─────────────────────────────────────────────────────────────────────────
  // initState：请求麦克风权限，初始化 STT/NMT 订阅
  // 【B-005 新增】新增调用 _checkModelsExist()
  // 查证报告 A-003 §6.1 & 查证报告 A-005 §12.3（步骤3）
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _requestMicPermission();
    _subscribeToSttChannel();
    _subscribeToNmtChannel();
    // 【B-005 新增】App 启动时检查模型文件是否已全部存在
    // 来源：查证报告 A-005 §12.3（步骤3：_checkModelsExist 在 initState 调用）
    _checkModelsExist();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // dispose：取消所有 StreamSubscription
  // 来源：https://api.dart.dev/stable/dart-async/StreamSubscription/cancel.html
  // 查证报告 A-003 第七章 §7.2
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _sttSubscription?.cancel();
    _sttSubscription = null;
    _nmtSubscription?.cancel();
    _nmtSubscription = null;
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 【B-005 新增】_checkModelsExist()
  // 检查所有模型文件是否已存在于 getApplicationDocumentsDirectory()/models/
  // 若全部存在则设置 _modelsReady = true，跳过下载
  // 来源：https://api.dart.dev/stable/dart-io/File/exists.html
  // 查证报告 A-005 §12.3（步骤3）& §3.2（路径说明）
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> _checkModelsExist() async {
    // getApplicationDocumentsDirectory() — Android 上对应 filesDir 区域
    // 来源：https://pub.dev/documentation/path_provider/latest/path_provider/getApplicationDocumentsDirectory.html
    // 查证报告 A-005 §3.2
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir = '${dir.path}/models';

    bool allExist = true;
    final Map<String, double> initialProgress = {};

    for (final model in _modelFiles) {
      final name = model['name']!;
      // File.exists() — 检测文件是否存在
      // 来源：https://api.dart.dev/stable/dart-io/File/exists.html
      final file = File('$modelsDir/$name');
      final exists = await file.exists();
      // 已存在的文件初始进度设为 1.0（代表"已就绪"）
      initialProgress[name] = exists ? 1.0 : 0.0;
      if (!exists) {
        allExist = false;
      }
    }

    if (mounted) {
      setState(() {
        _downloadProgress = initialProgress;
        _modelsReady = allExist;
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 【B-005 新增】_downloadModels()
  // 逐个下载模型文件；已存在的文件跳过；全部完成后调用 initModels
  // 来源：https://pub.dev/documentation/dio/latest/dio/Dio-class.html
  // 查证报告 A-005 §六（完整 dio 下载方案）& §12.3（步骤4）
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> _downloadModels() async {
    if (_isDownloading) return; // 防重入

    setState(() {
      _isDownloading = true;
      _downloadError = '';
    });

    try {
      // getApplicationDocumentsDirectory() — 查证报告 A-005 §3.2 & §6.2
      // 来源：https://pub.dev/documentation/path_provider/latest/path_provider/getApplicationDocumentsDirectory.html
      final dir = await getApplicationDocumentsDirectory();
      final modelsDir = '${dir.path}/models';

      // 创建 models/ 子目录（若不存在）
      // 来源：https://api.dart.dev/stable/dart-io/Directory/create.html
      await Directory(modelsDir).create(recursive: true);

      // Dio 实例 — 查证报告 A-005 §6.1
      // 来源：https://pub.dev/documentation/dio/latest/dio/Dio-class.html
      final dio = Dio();

      for (final model in _modelFiles) {
        final name = model['name']!;
        final url  = model['url']!;
        final savePath = '$modelsDir/$name';
        final file = File(savePath);

        // 已存在的文件跳过（查证报告 A-005 §12.3 步骤4：已存在的文件跳过）
        // 来源：https://api.dart.dev/stable/dart-io/File/exists.html
        if (await file.exists()) {
          if (mounted) {
            setState(() {
              _downloadProgress[name] = 1.0;
            });
          }
          continue;
        }

        // dio.download() — 流式下载文件到 savePath
        // 方法签名：download(Uri uri, dynamic savePath, {ProgressCallback? onReceiveProgress, ...})
        // 来源：https://pub.dev/documentation/dio/latest/dio/Dio/download.html
        // 查证报告 A-005 §6.1（download 方法签名）
        await dio.download(
          url,
          savePath,
          // onReceiveProgress — 回调签名：(int received, int total)
          // 来源：https://pub.dev/documentation/dio/latest/dio/Dio-class.html
          // 查证报告 A-005 §6.1（onReceiveProgress 回调签名）
          onReceiveProgress: (received, total) {
            if (total <= 0) return; // total 为 -1 时表示服务器未返回 Content-Length
            if (mounted) {
              // setState() 在 Dart Isolate（onReceiveProgress 回调）中直接调用
              // dio 的 onReceiveProgress 在 Flutter Dart 层触发，无需 runOnUiThread
              // 查证报告 A-005 §7.4（Flutter 层 setState 推进度）
              setState(() {
                _downloadProgress[name] = received / total;
              });
            }
          },
        );

        // 下载完成，确保进度显示为 1.0
        if (mounted) {
          setState(() {
            _downloadProgress[name] = 1.0;
          });
        }
      }

      // 全部文件下载完成（或已存在）→ 调用 initModels 通知 Kotlin 加载模型
      // 来源：https://api.flutter.dev/flutter/services/MethodChannel/invokeMethod.html
      // 使用已有 C2 MethodChannel，查证报告 A-005 §九（方案一机制图）
      // initModels 参数格式：{'srcLang': String, 'tgtLang': String}
      // 工作手册第七章 §7.2（initModels MethodChannel 处理器）
      await _controlChannel.invokeMethod<bool>('initModels', {
        'srcLang': 'zh',   // 源语言：中文
        'tgtLang': 'en',   // 目标语言：英文
      });

      if (mounted) {
        setState(() {
          _modelsReady = true;
          _isDownloading = false;
        });
      }
    } on DioException catch (e) {
      // DioException — dio 网络/IO 错误
      // 来源：https://pub.dev/documentation/dio/latest/dio/DioException-class.html
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadError = '下载失败: ${e.message ?? e.type.name}';
        });
      }
    } on PlatformException catch (e) {
      // PlatformException — MethodChannel 调用 initModels 失败
      // 来源：https://api.flutter.dev/flutter/services/PlatformException-class.html
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadError = 'initModels 调用失败: ${e.message}';
        });
      }
    } catch (e) {
      // 其他异常（文件系统错误等）
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadError = '错误: $e';
        });
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 麦克风权限请求
  // 来源：https://pub.dev/packages/permission_handler
  // 工作手册第五章 §5.5
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _requestMicPermission() async {
    // Permission.microphone.request() — https://pub.dev/documentation/permission_handler/latest/permission_handler/Permission/microphone.html
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ 需要麦克风权限才能测试录音功能')),
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // C4 订阅：STT 结果 + VAD 状态前缀处理
  // 来源：https://api.flutter.dev/flutter/services/EventChannel-class.html
  // 查证报告 A-003 §6.2 测试4 & 测试5
  // ─────────────────────────────────────────────────────────────────────────
  void _subscribeToSttChannel() {
    // receiveBroadcastStream — https://api.flutter.dev/flutter/services/EventChannel/receiveBroadcastStream.html
    _sttSubscription = _sttResultChannel
        .receiveBroadcastStream()
        .cast<String>()  // 类型转换 — 查证报告 A-003 §3.1
        .listen(
          (data) {
            // VAD 前缀判断：[VAD:SPEECH] 或 [VAD:SILENCE]
            // 查证报告 A-003 §6.2 测试4 & 第十章 §10.1 第5条
            if (data.startsWith('[VAD:')) {
              setState(() {
                _vadStatus = data == '[VAD:SPEECH]' ? '🎤 语音检测中' : '🔇 静音';
              });
            } else {
              // 普通 STT 识别文本
              setState(() {
                _sttText = data;
              });
            }
          },
          onError: (error) {
            setState(() {
              _sttText = 'STT 错误: $error';
            });
          },
        );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // C5 订阅：NMT 翻译结果
  // 来源：https://api.flutter.dev/flutter/services/EventChannel-class.html
  // 查证报告 A-003 §6.2 测试6
  // ─────────────────────────────────────────────────────────────────────────
  void _subscribeToNmtChannel() {
    _nmtSubscription = _nmtResultChannel
        .receiveBroadcastStream()
        .cast<String>()
        .listen(
          (data) {
            setState(() {
              _nmtText = data;
            });
          },
          onError: (error) {
            setState(() {
              _nmtText = 'NMT 错误: $error';
            });
          },
        );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试1：ping → pong
  // 来源：https://api.flutter.dev/flutter/services/MethodChannel/invokeMethod.html
  // 查证报告 A-003 §2.3
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _testPing() async {
    try {
      // invokeMethod — https://api.flutter.dev/flutter/services/MethodChannel/invokeMethod.html
      final result = await _inferenceChannel.invokeMethod<String>('ping');
      setState(() {
        _pingResult = result ?? '(无返回值)';
      });
    } on PlatformException catch (e) {
      setState(() {
        _pingResult = '错误: ${e.message}';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试2：OnnxRuntime 加载验证
  // 来源：https://onnxruntime.ai/docs/get-started/with-java.html
  // 查证报告 A-003 §2.3
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _testOnnxRuntime() async {
    try {
      final result =
          await _inferenceChannel.invokeMethod<String>('testOnnxRuntime');
      setState(() {
        _onnxResult = result ?? '(无返回值)';
      });
    } on PlatformException catch (e) {
      setState(() {
        _onnxResult = '错误: ${e.message}';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试3：开始录音 + 订阅 C3 音频流
  // 来源：https://docs.flutter.dev/platform-integration/platform-channels
  // 查证报告 A-003 §6.2 测试3
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    // 1. 调用 control MethodChannel startRecording
    try {
      await _controlChannel.invokeMethod<bool>('startRecording');
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('startRecording 错误: ${e.message}')),
      );
      return;
    }

    // 2. 订阅 C3 audio_stream EventChannel
    // 来源：https://api.flutter.dev/flutter/services/EventChannel/receiveBroadcastStream.html
    setState(() {
      _isRecordingAudio = true;
      _totalPcmSamples = 0;
    });

    _audioSubscription = _audioStreamChannel
        .receiveBroadcastStream()
        .cast<List<int>>()  // 查证报告 A-003 §3.4：Dart 侧接收 List<int>
        .listen(
          (pcmChunk) {
            setState(() {
              // 累加收到的样本数（查证报告 A-003 §6.2 测试3）
              _totalPcmSamples += pcmChunk.length;
            });
          },
          onError: (error) {
            setState(() {
              _isRecordingAudio = false;
            });
          },
        );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试3：停止录音
  // 查证报告 A-003 §6.2 测试3
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _stopRecording() async {
    // 1. 取消 C3 订阅（查证报告 A-003 第七章 §7.2）
    await _audioSubscription?.cancel();
    _audioSubscription = null;

    // 2. 调用 control MethodChannel stopRecording
    try {
      await _controlChannel.invokeMethod<bool>('stopRecording');
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('stopRecording 错误: ${e.message}')),
      );
    }

    setState(() {
      _isRecordingAudio = false;
      _vadStatus = '已停止';
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试7：TTS 播放翻译结果
  // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
  // 查证报告 A-003 §6.2 测试7
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _speakTranslation() async {
    try {
      // invokeMethod 传递参数 Map
      // 来源：https://api.flutter.dev/flutter/services/MethodChannel/invokeMethod.html
      await _controlChannel.invokeMethod<bool>('speakText', {
        'text': _nmtText,   // 当前翻译结果
        'lang': 'zh',       // TODO: 根据实际目标语言动态设置
      });
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('TTS 错误: ${e.message}')),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // build — UI
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GloTalk V3 测试台'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ══════════════════════════════════════════════════════════════════
          // 【B-005 新增】模型下载卡片 — 位于测试1之前
          // 来源：查证报告 A-005 §12.3（步骤5：下载 UI 卡片）
          // ══════════════════════════════════════════════════════════════════
          _ModelDownloadCard(
            modelFiles: _modelFiles,
            downloadProgress: _downloadProgress,
            isDownloading: _isDownloading,
            modelsReady: _modelsReady,
            downloadError: _downloadError,
            onDownload: _downloadModels,
          ),

          // ── 测试1：ping → pong ──────────────────────────────────────────
          _TestCard(
            index: '测试1',
            title: 'Channel 连通性 (ping)',
            // 来源：https://docs.flutter.dev/platform-integration/platform-channels
            resultText: _pingResult,
            child: ElevatedButton(
              onPressed: _testPing,
              child: const Text('发送 ping'),
            ),
          ),

          // ── 测试2：OnnxRuntime 加载 ──────────────────────────────────────
          _TestCard(
            index: '测试2',
            title: 'OnnxRuntime 加载验证',
            // 来源：https://onnxruntime.ai/docs/get-started/with-java.html
            resultText: _onnxResult,
            child: ElevatedButton(
              onPressed: _testOnnxRuntime,
              child: const Text('验证 OnnxRuntime'),
            ),
          ),

          // ── 测试3：麦克风 PCM 采集 ─────────────────────────────────────
          _TestCard(
            index: '测试3',
            title: '麦克风 PCM 采集',
            // 来源：https://developer.android.com/reference/android/media/AudioRecord
            resultText: _isRecordingAudio
                ? '录音中... 累计样本数：$_totalPcmSamples'
                : '总样本数：$_totalPcmSamples（已停止）',
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _isRecordingAudio ? null : _startRecording,
                  child: const Text('开始录音'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isRecordingAudio ? _stopRecording : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[100],
                  ),
                  child: const Text('停止录音'),
                ),
              ],
            ),
          ),

          // ── 测试4：VAD 状态 ────────────────────────────────────────────
          _TestCard(
            index: '测试4',
            title: 'VAD 语音活动检测',
            // VAD 状态通过 C4 stt_result 传递，[VAD:] 前缀区分
            // 查证报告 A-003 §6.2 测试4
            resultText: _vadStatus,
            child: const Text(
              '（VAD 状态由录音管线自动更新，无需手动触发）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ── 测试5：STT 识别结果 ────────────────────────────────────────
          _TestCard(
            index: '测试5',
            title: 'STT 语音识别结果',
            // 来源：C4 tech.glotalk/stt_result EventChannel
            resultText: _sttText,
            child: const Text(
              '（识别结果由推理管线自动推送，无需手动触发）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ── 测试6：NMT 翻译结果 ────────────────────────────────────────
          _TestCard(
            index: '测试6',
            title: 'NMT 翻译结果',
            // 来源：C5 tech.glotalk/nmt_result EventChannel
            resultText: _nmtText,
            child: const Text(
              '（翻译结果由推理管线自动推送，无需手动触发）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ── 测试7：TTS 播放 ────────────────────────────────────────────
          _TestCard(
            index: '测试7',
            title: 'TTS 播放翻译结果',
            // 来源：https://developer.android.com/reference/kotlin/android/speech/tts/TextToSpeech
            // 查证报告 A-003 §6.2 测试7
            resultText: '点击按钮播放当前翻译文本',
            child: ElevatedButton.icon(
              onPressed: _speakTranslation,
              icon: const Icon(Icons.play_arrow),
              label: const Text('▶ 播放翻译结果'),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 【B-005 新增】_ModelDownloadCard — 模型下载进度卡片 Widget
// 来源：查证报告 A-005 §12.3（步骤5：下载 UI 卡片）
// 职责：显示每个文件进度条，已存在显示"已就绪"，全部完成后显示就绪横幅
// ═══════════════════════════════════════════════════════════════════════════════
class _ModelDownloadCard extends StatelessWidget {
  final List<Map<String, String>> modelFiles;
  // 各文件进度 Map，key = 文件名，value = 0.0~1.0
  // 来源：查证报告 A-005 §6.1（onReceiveProgress 回调）
  final Map<String, double> downloadProgress;
  final bool isDownloading;
  final bool modelsReady;
  final String downloadError;
  final VoidCallback onDownload;

  const _ModelDownloadCard({
    required this.modelFiles,
    required this.downloadProgress,
    required this.isDownloading,
    required this.modelsReady,
    required this.downloadError,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      // 全部就绪时使用绿色边框，突出显示
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: modelsReady
              ? Colors.green
              : Theme.of(context).colorScheme.outline,
          width: modelsReady ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 卡片标题行 ───────────────────────────────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: modelsReady
                        ? Colors.green[100]
                        : Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    modelsReady ? '模型下载' : '模型下载',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '首次运行 — 下载 ONNX 模型',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── 全部就绪横幅 ──────────────────────────────────────────────
            if (modelsReady) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.green),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 18),
                    SizedBox(width: 8),
                    Text(
                      '模型已就绪，可开始测试',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],

            // ── 各文件进度条列表 ───────────────────────────────────────────
            // LinearProgressIndicator — 来源：https://api.flutter.dev/flutter/material/LinearProgressIndicator-class.html
            ...modelFiles.map((model) {
              final name = model['name']!;
              final progress = downloadProgress[name] ?? 0.0;
              final isDone = progress >= 1.0;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontSize: 12, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isDone
                              ? '✅ 已就绪'
                              : (isDownloading && progress > 0.0)
                                  ? '${(progress * 100).toStringAsFixed(1)}%'
                                  : '待下载',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDone
                                ? Colors.green
                                : Colors.grey[600],
                            fontWeight: isDone
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    // LinearProgressIndicator(value) — 0.0~1.0 对应进度
                    // 来源：https://api.flutter.dev/flutter/material/LinearProgressIndicator-class.html
                    // 查证报告 A-005 §7.4（Flutter 层 setState 推进度）
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[200],
                      color: isDone ? Colors.green : null,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ],
                ),
              );
            }),

            // ── 错误信息 ───────────────────────────────────────────────────
            if (downloadError.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.red[200]!),
                ),
                child: Text(
                  downloadError,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            ],

            const SizedBox(height: 12),

            // ── 下载按钮 ───────────────────────────────────────────────────
            if (!modelsReady)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  // 下载中时禁用按钮，防止重复触发
                  onPressed: isDownloading ? null : onDownload,
                  icon: isDownloading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(isDownloading ? '下载中，请稍候...' : '下载模型（约 500MB）'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _TestCard — 测试区块通用卡片 Widget
// ─────────────────────────────────────────────────────────────────────────────
class _TestCard extends StatelessWidget {
  final String index;
  final String title;
  final String resultText;
  final Widget child;

  const _TestCard({
    required this.index,
    required this.title,
    required this.resultText,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    index,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Text(
                resultText,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
