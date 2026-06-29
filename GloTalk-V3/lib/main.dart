// GloTalk-V3/lib/main.dart
// 任务编号：B-002
// 依据：智能体 A 查证报告 A-002（AgentA_查证报告_麦克风测试UI_20260629.md）
// 编写人：智能体 B（GloTalk 代码编辑）
// 日期：2026-06-29

import 'dart:async';
// dart:async — 来源：Dart 官方标准库，提供 StreamSubscription<T>
// https://api.dart.dev/stable/dart-async/StreamSubscription-class.html

import 'package:flutter/material.dart';
// Flutter Material UI — 来源：Flutter 官方 SDK
// https://api.flutter.dev/flutter/material/material-library.html

import 'package:flutter/services.dart';
// MethodChannel / EventChannel — 来源：Flutter 官方 services 库
// https://api.flutter.dev/flutter/services/MethodChannel-class.html
// https://api.flutter.dev/flutter/services/EventChannel-class.html

import 'package:permission_handler/permission_handler.dart';
// permission_handler 12.0.1 — 来源：pub.dev 官方文档
// https://pub.dev/packages/permission_handler

// ─────────────────────────────────────────────────────────────────────────────
// Channel 名称常量
// 查证来源：智能体 A 报告查证项 2（MethodChannel）、查证项 1（EventChannel）
// 铁律：两端字符串必须完全一致，大小写敏感
// ─────────────────────────────────────────────────────────────────────────────
const String _kControlChannel   = 'tech.glotalk/control';
const String _kAudioChannel     = 'tech.glotalk/audio_stream';

// ─────────────────────────────────────────────────────────────────────────────
// 入口
// 查证来源：GloTalk 工作手册 7.4 节 + Flutter 官方 async main 规范
// https://docs.flutter.dev/platform-integration/platform-channels
// WidgetsFlutterBinding.ensureInitialized() 必须在 async main 最前
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // ← 必须，async main 前置（工作手册 7.4 / 禁止项 ❌8）
  runApp(const GloTalkApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// 根 Widget
// ─────────────────────────────────────────────────────────────────────────────
class GloTalkApp extends StatelessWidget {
  const GloTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GloTalk V3 — 麦克风测试',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const TestHomePage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试主页
// ─────────────────────────────────────────────────────────────────────────────
class TestHomePage extends StatefulWidget {
  const TestHomePage({super.key});

  @override
  State<TestHomePage> createState() => _TestHomePageState();
}

class _TestHomePageState extends State<TestHomePage> {

  // ── Channel 实例 ────────────────────────────────────────────────────────────
  // MethodChannel — 查证来源：智能体 A 报告查证项 2
  // https://api.flutter.dev/flutter/services/MethodChannel-class.html
  static const MethodChannel _controlChannel = MethodChannel(_kControlChannel);

  // EventChannel — 查证来源：智能体 A 报告查证项 1
  // https://api.flutter.dev/flutter/services/EventChannel-class.html
  static const EventChannel _audioChannel = EventChannel(_kAudioChannel);

  // ── 测试1：Ping-Pong 状态 ────────────────────────────────────────────────────
  String _pingResult = '（未测试）';

  // ── 测试2：OnnxRuntime 加载状态 ─────────────────────────────────────────────
  String _onnxResult = '（未测试）';

  // ── 测试3：麦克风区域状态 ────────────────────────────────────────────────────

  // 权限状态文字 — 查证来源：智能体 A 报告查证项 3（permission_handler 12.0.1）
  String _permissionStatus = '（未请求）';

  // 录音状态
  bool _isRecording = false;

  // PCM 字节数累计 — 查证来源：智能体 A 报告数据类型链路总结
  // Kotlin 推送 List<Int>，Dart 收到 List<dynamic>，.length = short 帧数
  int _pcmSamplesReceived = 0;

  // StreamSubscription — 查证来源：智能体 A 报告查证项 4
  // https://api.dart.dev/stable/dart-async/StreamSubscription-class.html
  StreamSubscription<List<dynamic>>? _audioSub;

  // ─────────────────────────────────────────────────────────────────────────
  // dispose：必须取消 StreamSubscription，防止内存泄漏
  // 查证来源：智能体 A 报告查证项 5
  // https://api.flutter.dev/flutter/widgets/State/dispose.html
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _audioSub?.cancel();  // ← 取消订阅（查证项 5：防止 "setState called after dispose"）
    _audioSub = null;     // ← 置 null（查证项 4）
    super.dispose();      // ← 必须调用，且放最后（查证项 5：Flutter 框架要求）
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试1：MethodChannel ping → pong
  // 查证来源：智能体 A 报告查证项 2
  // invokeMethod 签名：Future<T?> invokeMethod<T>(String method, [dynamic arguments])
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _testPing() async {
    try {
      // 无参数调用写法 — 查证项 2 正确写法
      final result = await _controlChannel.invokeMethod<String>('ping');
      setState(() {
        _pingResult = result ?? '（空响应）';
      });
    } on PlatformException catch (e) {
      // PlatformException — 查证来源：查证项 2（必须用 try-catch 捕获）
      setState(() {
        _pingResult = '错误：${e.message}';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试2：OnnxRuntime 加载验证
  // 查证来源：智能体 A 报告查证项 2
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _testOnnx() async {
    try {
      final result = await _controlChannel.invokeMethod<String>('testOnnxLoad');
      setState(() {
        _onnxResult = result ?? '（空响应）';
      });
    } on PlatformException catch (e) {
      setState(() {
        _onnxResult = '错误：${e.message}';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试3-A：请求麦克风权限
  // 查证来源：智能体 A 报告查证项 3（permission_handler 12.0.1）
  // pub.dev: https://pub.dev/packages/permission_handler
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _requestMicPermission() async {
    // 写法 A — 最简洁（查证项 3 推荐用于 GloTalk）
    // Permission.microphone 是正确常量（非 Permission.audio）— 查证项 3
    final status = await Permission.microphone.request();

    String statusText;
    if (status.isGranted) {
      statusText = '✅ 已授权 (granted)';
    } else if (status.isPermanentlyDenied) {
      // 永久拒绝后引导设置 — 查证项 3 写法 C
      statusText = '❌ 永久拒绝，请前往设置开启';
      await openAppSettings(); // permission_handler 提供的工具函数
    } else if (status.isDenied) {
      statusText = '⚠️ 已拒绝 (denied)';
    } else if (status.isRestricted) {
      statusText = '🚫 受限 (restricted)';
    } else {
      // 覆盖其余 PermissionStatus 值（limited, provisional 等）— 查证项 3
      statusText = '？ 未知状态：$status';
    }

    setState(() {
      _permissionStatus = statusText;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试3-B：开始录音
  // 查证来源：智能体 A 报告查证项 2（invokeMethod）+ 查证项 1（EventChannel）
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    // 先取消已有订阅，防止重复订阅
    await _audioSub?.cancel();
    _audioSub = null;

    try {
      // MethodChannel 通知 Kotlin 开始录音
      // 无返回值写法 invokeMethod<void> — 查证项 2 最严格写法
      await _controlChannel.invokeMethod<void>('startRecording');

      // 订阅 EventChannel 音频数据流
      // receiveBroadcastStream() 返回 Stream<dynamic> — 查证项 1
      // Kotlin 推送 List<Int>，Dart 侧收到 List<dynamic> — 查证项 1 & 数据类型链路
      // StreamSubscription 订阅写法 — 查证项 4
      _audioSub = _audioChannel
          .receiveBroadcastStream()          // Stream<dynamic> — 查证项 1
          .cast<List<dynamic>>()             // cast — 查证项 1 正确订阅写法
          .listen(
            (List<dynamic> event) {
              // event.length = 本帧 short 样本数 — 数据类型链路总结
              setState(() {
                _pcmSamplesReceived += event.length;
              });
            },
            onError: (Object e) {
              // onError 回调 — 查证项 4 订阅写法
              setState(() {
                _permissionStatus = '音频流错误：$e';
              });
            },
            cancelOnError: false, // 遇错不自动取消订阅 — 查证项 4
          );

      setState(() {
        _isRecording = true;
        _pcmSamplesReceived = 0; // 重置计数
      });
    } on PlatformException catch (e) {
      setState(() {
        _permissionStatus = '开始录音错误：${e.message}';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 测试3-C：停止录音
  // 查证来源：智能体 A 报告查证项 2（invokeMethod）+ 查证项 4（cancel）
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _stopRecording() async {
    try {
      // MethodChannel 通知 Kotlin 停止录音 — 查证项 2
      await _controlChannel.invokeMethod<void>('stopRecording');

      // 取消 StreamSubscription — 查证项 4
      await _audioSub?.cancel();
      _audioSub = null; // ← 置 null — 查证项 4

      setState(() {
        _isRecording = false;
      });
    } on PlatformException catch (e) {
      setState(() {
        _permissionStatus = '停止录音错误：${e.message}';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI 构建
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GloTalk V3 — 节点测试'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── 测试1：MethodChannel Ping-Pong ─────────────────────────────
            _SectionCard(
              title: '测试 1：MethodChannel ping → pong',
              children: [
                Text('结果：$_pingResult'),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _testPing,
                  child: const Text('发送 ping'),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── 测试2：OnnxRuntime 加载验证 ────────────────────────────────
            _SectionCard(
              title: '测试 2：OnnxRuntime 加载验证',
              children: [
                Text('结果：$_onnxResult'),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _testOnnx,
                  child: const Text('验证 OnnxRuntime'),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── 测试3：麦克风测试区域 ──────────────────────────────────────
            _SectionCard(
              title: '测试 3：麦克风（VAD 前置节点）',
              children: [

                // 权限状态显示
                Text('权限状态：$_permissionStatus'),
                const SizedBox(height: 4),

                // PCM 字节数累计显示
                // event.length = short 样本数 × 2 bytes = 实际字节数
                // 此处直接显示 short 样本数，更直观
                Text(
                  '已接收 PCM 样本数：$_pcmSamplesReceived'
                  '${_pcmSamplesReceived > 0 ? "（≈ ${(_pcmSamplesReceived / 16000).toStringAsFixed(1)} 秒）" : ""}',
                ),

                const SizedBox(height: 12),

                // 请求麦克风权限按钮
                // 查证来源：查证项 3，Permission.microphone.request()
                ElevatedButton.icon(
                  onPressed: _requestMicPermission,
                  icon: const Icon(Icons.mic_none),
                  label: const Text('请求麦克风权限'),
                ),

                const SizedBox(height: 8),

                // 开始录音按钮
                // 查证来源：查证项 2（invokeMethod）+ 查证项 1（EventChannel）
                ElevatedButton.icon(
                  onPressed: _isRecording ? null : _startRecording,
                  // 录音中禁用，防止重复调用
                  icon: const Icon(Icons.fiber_manual_record, color: Colors.red),
                  label: const Text('开始录音'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording
                        ? Colors.grey.shade300
                        : Colors.green.shade100,
                  ),
                ),

                const SizedBox(height: 8),

                // 停止录音按钮
                // 查证来源：查证项 2（invokeMethod）+ 查证项 4（cancel）
                ElevatedButton.icon(
                  onPressed: _isRecording ? _stopRecording : null,
                  // 未录音时禁用
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('停止录音'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording
                        ? Colors.red.shade100
                        : Colors.grey.shade300,
                  ),
                ),

                const SizedBox(height: 8),

                // 录音状态指示
                Row(
                  children: [
                    Icon(
                      _isRecording
                          ? Icons.radio_button_on
                          : Icons.radio_button_off,
                      color: _isRecording ? Colors.red : Colors.grey,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isRecording ? '录音中...' : '已停止',
                      style: TextStyle(
                        color: _isRecording ? Colors.red : Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),

          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 辅助 Widget：带标题的测试区域卡片
// ─────────────────────────────────────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
