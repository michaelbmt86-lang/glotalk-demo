// 参考来源：
//   https://pub.dev/packages/sherpa_onnx (v1.13.2)
//   工作手册 V16 第七节「App 架构方向」
//
// 规范：main() 里只做 runApp，绝对不调用 initBindings() / SttService.initialize()
// initBindings() 由 SttService.initialize() 在自身内部第一行管理

import 'package:flutter/material.dart';
import 'screens/translate_screen.dart';

void main() {
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
