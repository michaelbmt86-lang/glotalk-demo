import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'call_screen.dart';

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});
  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  String? _lang;
  final _langs = [
    {'code':'zh','name':'中文','flag':'🇨🇳'},
    {'code':'en','name':'English','flag':'🇺🇸'},
    {'code':'ja','name':'日本語','flag':'🇯🇵'},
    {'code':'ko','name':'한국어','flag':'🇰🇷'},
    {'code':'es','name':'Español','flag':'🇪🇸'},
    {'code':'fr','name':'Français','flag':'🇫🇷'},
    {'code':'de','name':'Deutsch','flag':'🇩🇪'},
    {'code':'th','name':'ภาษาไทย','flag':'🇹🇭'},
    {'code':'vi','name':'Tiếng Việt','flag':'🇻🇳'},
    {'code':'id','name':'Indonesia','flag':'🇮🇩'},
    {'code':'ms','name':'Melayu','flag':'🇲🇾'},
    {'code':'ar','name':'العربية','flag':'🇸🇦'},
  ];

  Future<void> _go() async {
    if (_lang == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('myLang', _lang!);
    if (!mounted) return;
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(
      myLang: _lang!, room: ts.substring(ts.length-5), identity: '用户-${ts.substring(ts.length-8)}')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0A0A),
    appBar: AppBar(backgroundColor: const Color(0xFF0A0A0A),
      title: const Text('GloTalk', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 24))),
    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('我说的语言', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
        SizedBox(height: 4),
        Text('选择你的母语，对方会自动听到翻译', style: TextStyle(color: Color(0xFF888888), fontSize: 14)),
      ])),
      Expanded(child: GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 2.5, crossAxisSpacing: 12, mainAxisSpacing: 12),
        itemCount: _langs.length,
        itemBuilder: (ctx, i) {
          final l = _langs[i]; final sel = _lang == l['code'];
          return GestureDetector(onTap: () => setState(() => _lang = l['code']),
            child: AnimatedContainer(duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: sel ? const Color(0xFF00C853).withOpacity(0.15) : const Color(0xFF111111),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sel ? const Color(0xFF00C853) : const Color(0xFF222222), width: sel ? 2 : 1)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(l['flag']!, style: const TextStyle(fontSize: 24)),
                const SizedBox(width: 8),
                Text(l['name']!, style: TextStyle(color: sel ? const Color(0xFF00C853) : Colors.white,
                  fontSize: 15, fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
              ])));
        },
      )),
      Padding(padding: const EdgeInsets.all(24), child: SizedBox(width: double.infinity, height: 56,
        child: ElevatedButton(onPressed: _lang == null ? null : _go,
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF333333),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text('开始通话', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))))),
    ]),
  );
}
