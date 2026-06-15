import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'language_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _verify() async {
    final code = _ctrl.text.trim().toUpperCase();
    if (code.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    try {
      final r = await ApiService.verifyInvite(code);
      if (r['valid'] == true) {
        await ApiService.useInvite(code);
        final p = await SharedPreferences.getInstance();
        await p.setBool('isLoggedIn', true);
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LanguageScreen()));
      } else {
        setState(() => _error = '邀请码无效，请检查后重试');
      }
    } catch (e) {
      setState(() => _error = '网络错误，请检查连接');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0A0A),
    body: SafeArea(child: Padding(padding: const EdgeInsets.all(32), child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(width: 64, height: 64,
          decoration: BoxDecoration(color: const Color(0xFF00C853), borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.translate, color: Colors.white, size: 36)),
        const SizedBox(height: 32),
        const Text('GloTalk', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('输入邀请码开始使用', style: TextStyle(color: Color(0xFF888888), fontSize: 16)),
        const SizedBox(height: 48),
        TextField(
          controller: _ctrl,
          style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 4, fontWeight: FontWeight.w600),
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            hintText: 'GT-XXXXXX', hintStyle: const TextStyle(color: Color(0xFF444444)),
            filled: true, fillColor: const Color(0xFF111111),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF222222))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF222222))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00C853))),
          ),
          onSubmitted: (_) => _verify(),
        ),
        if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 14))],
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, height: 56,
          child: ElevatedButton(
            onPressed: _loading ? null : _verify,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: _loading ? const CircularProgressIndicator(color: Colors.white)
              : const Text('进入 GloTalk', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          )),
      ],
    ))),
  );
}
