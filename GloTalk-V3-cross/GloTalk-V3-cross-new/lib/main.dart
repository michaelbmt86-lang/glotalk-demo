import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      home: const TestScreen(),
    );
  }
}

class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  static const _channel = MethodChannel('tech.glotalk/inference');

  String _pingResult = '未测试';
  String _ortResult = '未测试';

  Future<void> _testPing() async {
    try {
      final result = await _channel.invokeMethod<String>('ping');
      setState(() => _pingResult = result ?? '无返回');
    } catch (e) {
      setState(() => _pingResult = '失败: $e');
    }
  }

  Future<void> _testOnnxRuntime() async {
    try {
      final result = await _channel.invokeMethod<String>('testOnnxRuntime');
      setState(() => _ortResult = result ?? '无返回');
    } catch (e) {
      setState(() => _ortResult = '失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('GloTalk V3 架构验证'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Flutter → MethodChannel → Kotlin → OnnxRuntime',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            _buildCard('测试1：MethodChannel 通信', _pingResult, _testPing),
            const SizedBox(height: 20),
            _buildCard('测试2：OnnxRuntime 加载', _ortResult, _testOnnxRuntime),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(String title, String result, VoidCallback onTest) {
    final isOk = result.contains('pong') || result.contains('OK');
    final isFail = result.contains('失败');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOk ? Colors.green : isFail ? Colors.red : Colors.grey,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(result,
              style: TextStyle(
                color: isOk ? Colors.green : isFail ? Colors.red : Colors.grey,
              )),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: onTest, child: const Text('运行测试')),
        ],
      ),
    );
  }
}