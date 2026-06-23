import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

const String kServerUrl = 'https://glotalk.tech';
const String kAccessToken = 'glotalk2026';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.microphone.request();
  await Permission.bluetooth.request();
  await Permission.bluetoothConnect.request();
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
        Uri.parse('$kServerUrl/invite-al/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': _controller.text.trim()}),
      );
      final data = jsonDecode(res.body);
      if (!mounted) return;
      if (data['ok'] == true) {
        final roomId = data['roomId'] ?? _controller.text.trim();
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => LanguagePage(
            inviteCode: _controller.text.trim(),
            roomId: roomId,
          ),
        ));
      } else {
        setState(() { _error = data['error'] ?? '邀请码无效，请重试'; });
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
  final String roomId;
  const LanguagePage({super.key, required this.inviteCode, required this.roomId});
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
                    roomId: widget.roomId,
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
  final String roomId;
  final String myLang;
  final String theirLang;
  const CallPage({super.key, required this.roomId,
    required this.myLang, required this.theirLang});
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  Room? _room;
  bool _muted = false;
  String _status = '连接中...';
  final List<Map<String, String>> _captions = [];

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final identity = 'user-${DateTime.now().millisecondsSinceEpoch}';
      final tokenUri = Uri.parse('$kServerUrl/livekit-token').replace(
        queryParameters: {
          'room': widget.roomId,
          'identity': identity,
          'lang': widget.myLang,
        },
      );
      final tokenRes = await http.get(
        tokenUri,
        headers: {'x-glotalk-token': kAccessToken},
      );
      final tokenData = jsonDecode(tokenRes.body);
      final token = tokenData['token'];
      const livekitUrl = 'wss://glotalk-nppyx7kk.livekit.cloud';

      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );

      // 监听字幕数据包
      room.addListener(() {});
      room.on<DataReceivedEvent>((event) {
        try {
          final text = utf8.decode(event.data);
          final json = jsonDecode(text);
          if (json['type'] == 'caption' && mounted) {
            setState(() {
              _captions.add({
                'text': json['text'] ?? '',
                'lang': json['lang'] ?? '',
              });
              if (_captions.length > 10) _captions.removeAt(0);
            });
          }
        } catch (_) {}
      });

      await room.connect(livekitUrl, token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      // 启动Bot（我说的语言→对方语言）
      final botUri = Uri.parse('$kServerUrl/start-bot').replace(
        queryParameters: {
          'room': widget.roomId,
          'identity': 'bot-${widget.myLang}-${DateTime.now().millisecondsSinceEpoch}',
          'source': widget.myLang,
          'target': widget.theirLang,
        },
      );
      await http.get(botUri);

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

  Future<void> _stopBot() async {
    try {
      final stopUri = Uri.parse('$kServerUrl/stop-bot').replace(
        queryParameters: {
          'room': widget.roomId,
          'source': widget.myLang,
        },
      );
      await http.get(stopUri);
    } catch (_) {}
  }

  Future<void> _disconnect() async {
    await _stopBot();
    await _room?.disconnect();
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _stopBot();
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
            const SizedBox(height: 24),
            const Text('GloTalk', style: TextStyle(
              color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(_status, style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 16),

            // 字幕显示区域
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _captions.isEmpty
                  ? const Center(
                      child: Text('翻译字幕将在这里显示',
                        style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: _captions.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          _captions[i]['text'] ?? '',
                          style: const TextStyle(
                            color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
              ),
            ),

            const SizedBox(height: 24),
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
            const SizedBox(height: 40),
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
