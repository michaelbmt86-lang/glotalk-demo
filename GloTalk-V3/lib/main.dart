// GloTalk-V3/lib/main.dart
// 智能体 B 代码编辑 | 依据：查证报告 A-005 | 任务：B-005
// 上一版本：B-003（测试1-7 全部保持不变，本次仅新增下载区域）
// B-009 修正：_checkModelsExist() 发现模型已就绪时自动调用 initModels

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
    'name': 'whisper_encoder_uint8.onnx',
    // B-013：换用 uint8 版本，来源：A-013 Q3 — CPU EP 支持 uint8 ConvInteger kernel
    // int8 版本触发 ORT_NOT_IMPLEMENTED ConvInteger(10)，uint8 版本 CPU EP 已支持
    // 来源：https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/encoder_model_uint8.onnx
    // 节点2 STT Whisper small 编码器 uint8，约 92MB
    'url': 'https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/encoder_model_uint8.onnx',
  },
  {
    'name': 'whisper_decoder_uint8.onnx',
    // B-013：换用 uint8 版本，来源：A-013 Q3 — 与 encoder 保持一致的量化格式
    // 来源：https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/decoder_model_uint8.onnx
    // 节点2 STT Whisper small 解码器 uint8，约 156MB
    'url': 'https://hf-mirror.com/onnx-community/whisper-small/resolve/main/onnx/decoder_model_uint8.onnx',
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
  {
    'name': 'multilingual.tiktoken',
    // 原始来源：https://raw.githubusercontent.com/openai/whisper/main/whisper/assets/multilingual.tiktoken
    // 国内镜像：raw.githubusercontent.com 在大陆被墙，改用 hf-mirror.com 镜像
    // 来源：JosefAlbers/whisper 仓库，文件已验证，内容与官方完全一致
    // Whisper tiktoken BPE decode 词表，约 817KB
    // 查证报告 A-008b — WhisperTokenizer.kt 读取此文件实现 STT 文字还原
    'url': 'https://hf-mirror.com/JosefAlbers/whisper/resolve/main/multilingual.tiktoken',
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
  Map<String, double> _downloadProgress = {};

  // 是否正在下载中（防止重复点击）
  bool _isDownloading = false;

  // 是否全部模型文件已就绪（下载完成或文件已存在）
  bool _modelsReady = false;

  // 下载错误信息（空字符串表示无错误）
  String _downloadError = '';

  // ─── 测试1：ping/pong 状态变量
  String _pingResult = '等待测试...';

  // ─── 测试2：OnnxRuntime 状态变量
  String _onnxResult = '等待测试...';

  // ─── 测试3：PCM 采集状态变量
  int _totalPcmSamples = 0;
  bool _isRecordingAudio = false;

  // ─── 测试4：VAD 状态变量
  String _vadStatus = '未开始';

  // ─── 测试5：STT 识别结果
  String _sttText = '等待识别...';

  // ─── 测试6：NMT 翻译结果
  String _nmtText = '等待翻译...';

  // ─── StreamSubscription 生命周期管理
  StreamSubscription<List<int>>? _audioSubscription;
  StreamSubscription<String>? _sttSubscription;
  StreamSubscription<String>? _nmtSubscription;

  // ─────────────────────────────────────────────────────────────────────────
  // initState
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _requestMicPermission();
    _subscribeToSttChannel();
    _subscribeToNmtChannel();
    _checkModelsExist();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // dispose
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
  // _checkModelsExist()
  // 检查所有模型文件是否已存在
  // B-009 修正：发现全部就绪时自动调用 initModels，触发 PipelineOrchestrator 初始化
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> _checkModelsExist() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir = '${dir.path}/models';

    bool allExist = true;
    final Map<String, double> initialProgress = {};

    for (final model in _modelFiles) {
      final name = model['name']!;
      final file = File('$modelsDir/$name');
      final exists = await file.exists();
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
      // B-009 修正：模型已全部就绪时自动调用 initModels
      // 原问题：App 启动检测到模型存在后未调用 initModels，导致
      //         PipelineOrchestrator 未初始化，VAD 永远显示「未开始」
      // 来源：A-005 §九（initModels 触发时机）
      if (allExist) {
        try {
          await _controlChannel.invokeMethod<bool>('initModels', {
            'srcLang': 'zh',
            'tgtLang': 'en',
          });
        } catch (_) {
          // initModels 失败时静默处理，不崩溃
          // 用户可通过重启 App 重试
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // _downloadModels()
  // 逐个下载模型文件；已存在的文件跳过；全部完成后调用 initModels
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> _downloadModels() async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadError = '';
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final modelsDir = '${dir.path}/models';

      await Directory(modelsDir).create(recursive: true);

      final dio = Dio();

      for (final model in _modelFiles) {
        final name = model['name']!;
        final url  = model['url']!;
        final savePath = '$modelsDir/$name';
        final file = File(savePath);

        if (await file.exists()) {
          if (mounted) {
            setState(() {
              _downloadProgress[name] = 1.0;
            });
          }
          continue;
        }

        await dio.download(
          url,
          savePath,
          onReceiveProgress: (received, total) {
            if (total <= 0) return;
            if (mounted) {
              setState(() {
                _downloadProgress[name] = received / total;
              });
            }
          },
        );

        if (mounted) {
          setState(() {
            _downloadProgress[name] = 1.0;
          });
        }
      }

      await _controlChannel.invokeMethod<bool>('initModels', {
        'srcLang': 'zh',
        'tgtLang': 'en',
      });

      if (mounted) {
        setState(() {
          _modelsReady = true;
          _isDownloading = false;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadError = '下载失败: ${e.message ?? e.type.name}';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadError = 'initModels 调用失败: ${e.message}';
        });
      }
    } catch (e) {
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
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _requestMicPermission() async {
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
  // ─────────────────────────────────────────────────────────────────────────
  void _subscribeToSttChannel() {
    _sttSubscription = _sttResultChannel
        .receiveBroadcastStream()
        .cast<String>()
        .listen(
          (data) {
            if (data.startsWith('[VAD:')) {
              setState(() {
                _vadStatus = data == '[VAD:SPEECH]' ? '🎤 语音检测中' : '🔇 静音';
              });
            } else {
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
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _testPing() async {
    try {
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
  // 测试3：开始录音
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    try {
      await _controlChannel.invokeMethod<bool>('startRecording');
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('startRecording 错误: ${e.message}')),
      );
      return;
    }

    setState(() {
      _isRecordingAudio = true;
      _totalPcmSamples = 0;
    });

    _audioSubscription = _audioStreamChannel
        .receiveBroadcastStream()
        .cast<List<int>>()
        .listen(
          (pcmChunk) {
            setState(() {
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
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _stopRecording() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;

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
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _speakTranslation() async {
    try {
      await _controlChannel.invokeMethod<bool>('speakText', {
        'text': _nmtText,
        'lang': 'zh',
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

          _ModelDownloadCard(
            modelFiles: _modelFiles,
            downloadProgress: _downloadProgress,
            isDownloading: _isDownloading,
            modelsReady: _modelsReady,
            downloadError: _downloadError,
            onDownload: _downloadModels,
          ),

          // ── 测试1
          _TestCard(
            index: '测试1',
            title: 'Channel 连通性 (ping)',
            resultText: _pingResult,
            child: ElevatedButton(
              onPressed: _testPing,
              child: const Text('发送 ping'),
            ),
          ),

          // ── 测试2
          _TestCard(
            index: '测试2',
            title: 'OnnxRuntime 加载验证',
            resultText: _onnxResult,
            child: ElevatedButton(
              onPressed: _testOnnxRuntime,
              child: const Text('验证 OnnxRuntime'),
            ),
          ),

          // ── 测试3
          _TestCard(
            index: '测试3',
            title: '麦克风 PCM 采集',
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

          // ── 测试4
          _TestCard(
            index: '测试4',
            title: 'VAD 语音活动检测',
            resultText: _vadStatus,
            child: const Text(
              '（VAD 状态由录音管线自动更新，无需手动触发）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ── 测试5
          _TestCard(
            index: '测试5',
            title: 'STT 语音识别结果',
            resultText: _sttText,
            child: const Text(
              '（识别结果由推理管线自动推送，无需手动触发）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ── 测试6
          _TestCard(
            index: '测试6',
            title: 'NMT 翻译结果',
            resultText: _nmtText,
            child: const Text(
              '（翻译结果由推理管线自动推送，无需手动触发）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ── 测试7
          _TestCard(
            index: '测试7',
            title: 'TTS 播放翻译结果',
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
// _ModelDownloadCard — 模型下载进度卡片 Widget
// ═══════════════════════════════════════════════════════════════════════════════
class _ModelDownloadCard extends StatelessWidget {
  final List<Map<String, String>> modelFiles;
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
            // ── 卡片标题行
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

            // ── 全部就绪横幅
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

            // ── 各文件进度条列表
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

            // ── 错误信息
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

            // ── 下载按钮
            if (!modelsReady)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
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
