import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const GloTalkApp());
}

class GloTalkApp extends StatelessWidget {
  const GloTalkApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GloTalk',
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      home: const InvitePage(),
    );
  }
}

class InvitePage extends StatefulWidget {
  const InvitePage({super.key});
  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  final _controller = TextEditingController();
  bool _loading = false;
  String _error = '';

  Future<void> _verify() async {
    setState(() { _loading = true; _error = ''; });
    try {
      final res = await http.post(
        Uri.parse('https://glotalk.tech/invite-al/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': _controller.text.trim()}),
      );
      final data = jsonDecode(res.body);
      if (!mounted) return;
      if (data['success'] == true) {
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => LanguagePage(inviteCode: _controller.text.trim()),
        ));
      } else {
        setState(() { _error = '邀请码无效，请重试'; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '网络错误，请检查连接'; });
    }
    setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('GloTalk', style: TextStyle(
                color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('跨语言实时翻译', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 48),
              TextField(
                controller: _controller,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '输入邀请码',
                  hintStyle: const TextStyle(color: Colors.grey),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.grey)),
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_error, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, height: 50,
                child: ElevatedButton(
                  onPressed: _loading ? null : _verify,
                  child: _loading
                    ? const CircularProgressIndicator()
                    : const Text('进入'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LanguagePage extends StatefulWidget {
  final String inviteCode;
  const LanguagePage({super.key, required this.inviteCode});
  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  String _myLang = 'zh';
  String _theirLang = 'en';

  final _languages = {
    'zh': '中文', 'en': 'English', 'ja': '日本語',
    'ko': '한국어', 'es': 'Español', 'fr': 'Français',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('选择语言', style: TextStyle(color: Colors.white))),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('我说的语言', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            _buildDropdown(_myLang, (v) => setState(() => _myLang = v!)),
            const SizedBox(height: 24),
            const Text('对方的语言', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            _buildDropdown(_theirLang, (v) => setState(() => _theirLang = v!)),
            const Spacer(),
            SizedBox(width: double.infinity, height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => CallPage(
                    inviteCode: widget.inviteCode,
                    myLang: _myLang,
                    theirLang: _theirLang,
                  ),
                )),
                child: const Text('开始通话'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown(String value, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: Colors.grey[900],
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.grey)),
      ),
      items: _languages.entries.map((e) =>
        DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
      onChanged: onChanged,
    );
  }
}

class CallPage extends StatefulWidget {
  final String inviteCode;
  final String myLang;
  final String theirLang;
  const CallPage({super.key, required this.inviteCode,
    required this.myLang, required this.theirLang});
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  Room? _room;
  bool _muted = false;
  String _status = '连接中...';

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndConnect();
  }

  Future<void> _requestPermissionsAndConnect() async {
    final micStatus = await Permission.microphone.request();
    if (!mounted) return;
    if (micStatus.isGranted) {
      _connect();
    } else {
      setState(() { _status = '需要麦克风权限才能通话'; });
    }
  }

  Future<void> _connect() async {
    try {
      final res = await http.post(
        Uri.parse('https://glotalk.tech/alibaba-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'inviteCode': widget.inviteCode,
          'lang': widget.myLang,
          'theirLang': widget.theirLang,
        }),
      );
      final data = jsonDecode(res.body);
      final token = data['token'];
      final url = data['url'] ?? 'wss://glotalk-nppyx7kk.livekit.cloud';

      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      await room.connect(url, token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      if (!mounted) return;
      setState(() {
        _room = room;
        _status = '已连接，开始说话';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _status = '连接失败：$e'; });
    }
  }

  Future<void> _disconnect() async {
    await _room?.disconnect();
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _room?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            const Text('GloTalk', style: TextStyle(
              color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(_status, style: const TextStyle(color: Colors.grey)),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CircleButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  color: _muted ? Colors.grey : Colors.blue,
                  onTap: () async {
                    await _room?.localParticipant?.setMicrophoneEnabled(_muted);
                    if (!mounted) return;
                    setState(() => _muted = !_muted);
                  },
                ),
                const SizedBox(width: 32),
                _CircleButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  onTap: _disconnect,
                ),
              ],
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72, height: 72,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 32),
      ),
    );
  }
}
