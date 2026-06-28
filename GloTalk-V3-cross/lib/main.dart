// 参考来源：
//   https://pub.dev/packages/sherpa_onnx (v1.13.2)
//   https://api.flutter.dev/flutter/widgets/WidgetsFlutterBinding/ensureInitialized.html
//   工作手册 V16 第七节「App 架构方向」
//
// 规范：main() 必须先调用 WidgetsFlutterBinding.ensureInitialized()
//   原因：App 启动时 translate_screen.dart 会立即调用 record.hasPermission()
//   Flutter 官方文档明确要求：使用插件的 App 必须先初始化 Flutter 引擎绑定
//   initBindings() 由 SttService.initialize() 在自身内部第一行管理

import 'package:flutter/material.dart';
import 'screens/translate_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GloTalkApp());
}

class GloTalkApp extends StatelessWidget {
  const GloTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GloTalk V3',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TranslateScreen(),
    );
  }
}
