import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';
import 'language_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1500), vsync: this);
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
    _check();
  }

  Future<void> _check() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final ok = prefs.getBool('isLoggedIn') ?? false;
    Navigator.pushReplacement(context, MaterialPageRoute(
      builder: (_) => ok ? const LanguageScreen() : const LoginScreen()));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0A0A),
    body: Center(child: FadeTransition(opacity: _fade, child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(width: 100, height: 100,
          decoration: BoxDecoration(color: const Color(0xFF00C853), borderRadius: BorderRadius.circular(24)),
          child: const Icon(Icons.translate, color: Colors.white, size: 56)),
        const SizedBox(height: 24),
        const Text('GloTalk', style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('Your World, Translated', style: TextStyle(color: Color(0xFF888888), fontSize: 16)),
      ],
    ))),
  );
}
