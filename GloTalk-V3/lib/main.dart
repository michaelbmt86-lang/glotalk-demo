// GloTalk-V3/lib/main.dart
// 智能体 B 代码编辑 | 依据：查证报告 A-003 | 任务：B-003

// Flutter SDK — https://api.flutter.dev/flutter/material/material-library.html
import 'package:flutter/material.dart';
// Platform channels — https://docs.flutter.dev/platform-integration/platform-channels
import 'package:flutter/services.dart';
// StreamSubscription — https://api.dart.dev/stable/dart-async/StreamSubscription-class.html
import 'dart:async';
// permission_handler — https://pub.dev/packages/permission_handler
import 'package:permission_handler/permission_handler.dart';

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
  // 查证报告 A-003 §6.1：权限在 initState 中申请
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _requestMicPermission();
    _subscribeToSttChannel();
    _subscribeToNmtChannel();
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
