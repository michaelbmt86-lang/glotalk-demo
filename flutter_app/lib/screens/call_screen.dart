import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/api_service.dart';

class CallScreen extends StatefulWidget {
  final String myLang, room, identity;
  const CallScreen({super.key, required this.myLang, required this.room, required this.identity});
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Room? _room;
  bool _connecting = true, _connected = false, _muted = false;
  String _status = '正在连接...';
  int _peers = 0;
  Duration _dur = Duration.zero;
  final _sw = Stopwatch();

  @override
  void initState() { super.initState(); _connect(); }

  Future<void> _connect() async {
    try {
      final td = await ApiService.getLiveKitToken(room: widget.room, identity: widget.identity, lang: widget.myLang);
      final room = Room();
      _room = room;
      room.addListener(() { if (mounted) setState(() => _peers = room.remoteParticipants.length + 1); });
      await room.connect(td['url'], td['token'], roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true));
      await room.localParticipant?.setMicrophoneEnabled(true);
      _sw.start();
      Stream.periodic(const Duration(seconds: 1)).listen((_) { if (mounted) setState(() => _dur = _sw.elapsed); });
      setState(() { _connecting = false; _connected = true; _status = '通话中'; _peers = room.remoteParticipants.length + 1; });
    } catch (e) {
      setState(() { _connecting = false; _status = '连接失败: $e'; });
    }
  }

  Future<void> _mute() async {
    await _room?.localParticipant?.setMicrophoneEnabled(_muted);
    setState(() => _muted = !_muted);
  }

  Future<void> _end() async { _sw.stop(); await _room?.disconnect(); if (mounted) Navigator.pop(context); }

  String _fmt(Duration d) => '${d.inMinutes.toString().padLeft(2,'0')}:${(d.inSeconds%60).toString().padLeft(2,'0')}';

  String _name(String c) => {'zh':'中文','en':'English','ja':'日本語','ko':'한국어','es':'Español','fr':'Français','de':'Deutsch','th':'ภาษาไทย','vi':'Tiếng Việt','id':'Indonesia','ms':'Melayu','ar':'العربية'}[c] ?? c;

  @override
  void dispose() { _sw.stop(); _room?.disconnect(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0A0A),
    body: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.all(20), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_connected ? '通话中' : _status, style: TextStyle(color: _connected ? const Color(0xFF00C853) : Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          if (_connected) Text(_fmt(_dur), style: const TextStyle(color: Color(0xFF888888), fontSize: 14)),
        ]),
        Row(children: [const Icon(Icons.people, color: Color(0xFF888888), size: 16), const SizedBox(width: 4), Text('$_peers', style: const TextStyle(color: Color(0xFF888888)))]),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF00C853).withOpacity(0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF00C853))),
          child: Text('我说 ${_name(widget.myLang)}', style: const TextStyle(color: Color(0xFF00C853), fontSize: 13, fontWeight: FontWeight.w500))),
        const SizedBox(width: 8),
        const Icon(Icons.swap_horiz, color: Color(0xFF888888), size: 20),
        const SizedBox(width: 8),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF333333))),
          child: const Text('自动翻译', style: TextStyle(color: Color(0xFF888888), fontSize: 13))),
      ])),
      const SizedBox(height: 24),
      Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('对方说（翻译）', style: TextStyle(color: Color(0xFF888888), fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Expanded(child: Container(width: double.infinity, padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222222))),
          child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.volume_up, color: Color(0xFF333333), size: 48),
            const SizedBox(height: 12),
            Text(_connecting ? '正在连接...' : '等待对方说话...', style: const TextStyle(color: Color(0xFF555555), fontSize: 14)),
          ])))),
      ]))),
      const SizedBox(height: 16),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('我说的话', style: TextStyle(color: Color(0xFF888888), fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Container(width: double.infinity, height: 80, padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFF0D1F12), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF1A3A20))),
          child: const Text('开始说话...', style: TextStyle(color: Color(0xFF555555), fontSize: 15))),
      ])),
      const SizedBox(height: 32),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        GestureDetector(onTap: _mute, child: Container(width: 64, height: 64,
          decoration: BoxDecoration(color: _muted ? const Color(0xFFEF4444) : const Color(0xFF222222), shape: BoxShape.circle),
          child: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white, size: 28))),
        GestureDetector(onTap: _end, child: Container(width: 80, height: 80,
          decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
          child: const Icon(Icons.call_end, color: Colors.white, size: 36))),
        Container(width: 64, height: 64,
          decoration: const BoxDecoration(color: Color(0xFF222222), shape: BoxShape.circle),
          child: const Icon(Icons.volume_up, color: Colors.white, size: 28)),
      ])),
      const SizedBox(height: 32),
    ])),
  );
}
