// GloTalk V3 — 翻译管线验证分支
// 架构：设备端 STT → 翻译 → TTS（无 LiveKit，无服务器）
// 对应技术路线 V16：sherpa_onnx + flutter_onnxruntime + opus-mt-zh-en
// 此文件只负责：App 初始化 + 路由到 VerifyScreen

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'verify_screen.dart';

// ─────────────────────────────────────────────
// 入口
// ─────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 锁定竖屏，与 alibaba-v1 保持一致
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const GloTalkV3App());
}

// ─────────────────────────────────────────────
// App 根组件
// ─────────────────────────────────────────────
class GloTalkV3App extends StatelessWidget {
  const GloTalkV3App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GloTalk V3 验证',
      debugShowCheckedModeBanner: true, // 保留 debug 标识，方便区分验证分支
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0066FF), // GloTalk 品牌蓝
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0066FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      // 直接进验证页，跳过邀请码 / LiveKit 登录
      home: const AppInitWrapper(),
    );
  }
}

// ─────────────────────────────────────────────
// 初始化包装器
// 负责：检查模型目录是否存在 → 显示启动状态 → 进入 VerifyScreen
// ─────────────────────────────────────────────
class AppInitWrapper extends StatefulWidget {
  const AppInitWrapper({super.key});

  @override
  State<AppInitWrapper> createState() => _AppInitWrapperState();
}

class _AppInitWrapperState extends State<AppInitWrapper> {
  String _status = '正在初始化…';
  bool _ready = false;
  String? _errorMsg;

  // 模型目录结构（对应 V16 技术栈表）
  // 实际模型文件由 verify_screen.dart 负责加载，
  // 这里只检查目录是否可写，确保设备环境正常。
  static const _expectedSubDirs = [
    'models/stt',   // sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8
    'models/mt',    // opus-mt-zh-en ONNX encoder + decoder + tokenizer
    'models/tts',   // vits-piper-en_US-libritts_r-medium
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      setState(() => _status = '检查存储权限…');

      final appDir = await getApplicationDocumentsDirectory();

      setState(() => _status = '检查模型目录…');

      final missingDirs = <String>[];
      for (final sub in _expectedSubDirs) {
        final dir = Directory('${appDir.path}/$sub');
        if (!await dir.exists()) {
          missingDirs.add(sub);
        }
      }

      if (missingDirs.isNotEmpty) {
        // 目录不存在是正常情况（首次运行），
        // VerifyScreen 会负责引导用户下载模型
        setState(() {
          _status = '检测到 ${missingDirs.length} 个模型目录尚未建立\n'
              '进入验证页后可下载模型';
        });
        await Future.delayed(const Duration(milliseconds: 800));
      } else {
        setState(() => _status = '模型目录已就绪 ✅');
        await Future.delayed(const Duration(milliseconds: 400));
      }

      setState(() => _ready = true);
    } catch (e) {
      setState(() {
        _errorMsg = '初始化失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return _ErrorPage(message: _errorMsg!);
    }

    if (_ready) {
      // 直接跳到翻译管线验证页
      return const VerifyScreen();
    }

    // 启动 Splash
    return Scaffold(
      backgroundColor: const Color(0xFF0066FF),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo 占位（正式版替换为 SVG）
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Center(
                  child: Text(
                    'GT',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0066FF),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'GloTalk V3',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '翻译管线验证分支',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 48),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 错误页（初始化失败时显示）
// ─────────────────────────────────────────────
class _ErrorPage extends StatelessWidget {
  final String message;
  const _ErrorPage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 56),
                const SizedBox(height: 20),
                const Text(
                  '初始化失败',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () {
                    // 重启 App
                    SystemNavigator.pop();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新启动'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
