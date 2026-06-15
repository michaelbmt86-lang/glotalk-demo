import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/splash_screen.dart';

void main() { runApp(const GloTalkApp()); }

class GloTalkApp extends StatelessWidget {
  const GloTalkApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GloTalk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00C853), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        useMaterial3: true,
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja'), Locale('ko')],
      home: const SplashScreen(),
    );
  }
}
