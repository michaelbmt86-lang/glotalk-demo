// GloTalk 路线B升级版 — call_screen.dart
// 参考来源：google-gemini/gemini-live-api-examples
//   src/app/session/[id]/watch/page.tsx → 听众端逻辑
//   src/app/session/[id]/broadcast/page.tsx → 主讲人端逻辑
// LiveKit Flutter SDK：livekit_client（pub.dev 官方）
// 架构：Flutter App 只管 UI，翻译全在服务器 Bot 完成

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import '../services/api_service.dart';

// ── 字幕数据结构（来自官方 TranscriptEntry）──
class TranscriptEntry {
  final String id;
  String text;
  bool isFinal;
  TranscriptEntry({required this.id, required this.text, required this.isFinal});
}

class CallScreen extends StatefulWidget {
  final String room;
  final String identity;
  final String role; // "organizer" | "attendee"
  final String sessionId;

  const CallScreen({
    super.key,
    required this.room,
    required this.identity,
    required this.role,
    required this.sessionId,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  bool _connecting = true;
  bool _micEnabled = true;
  String _status = '连接中...';

  // 字幕（来自官方 transcripts state）
  final List<TranscriptEntry> _transcripts = [];

  // 语言切换（来自官方 currentLanguage + translatorIdentity state）
  String _currentLanguage = 'original';
  String? _translatorIdentity;
  bool _langSwitching = false;

  // 主讲人：翻译列表（来自官方 translations state）
  List<Map<String, dynamic>> _translations = [];

  static const String baseUrl = 'https://glotalk.tech';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  // ── 连接 LiveKit 房间 ──
  Future<void> _connect() async {
    try {
      // 主讲人可发布音频，听众只订阅
      final isOrganizer = widget.role == 'organizer';

      final tokenData = await ApiService.getLiveKitToken(
        room: widget.room,
        identity: widget.identity,
        lang: 'zh',
      );

      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // 听众：autoSubscribe: false，手动控制订阅（来自官方）
          defaultAudioPublishOptions: isOrganizer
              ? const AudioPublishOptions()
              : null,
        ),
      );

      _room = room;

      // 注册事件监听器（来自官方 RoomEvent 处理）
      _listener = room.createListener();
      _listener!
        ..on<TrackSubscribedEvent>(_onTrackSubscribed)
        ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
        ..on<DataReceivedEvent>(_onDataReceived)
        ..on<ParticipantConnectedEvent>((_) => _updateSubscriptions())
        ..on<TrackPublishedEvent>((_) => _updateSubscriptions());

      await room.connect(tokenData['url'], tokenData['token']);

      if (isOrganizer) {
        await room.localParticipant?.setMicrophoneEnabled(true);
        // 主讲人定时轮询翻译状态
        _startTranslationsPolling();
      }

      if (mounted) {
        setState(() {
          _connecting = false;
          _status = isOrganizer ? '直播中' : '收听中';
        });
      }
    } catch (e) {
      if (mounted) setState(() { _connecting = false; _status = '连接失败: $e'; });
    }
  }

  // ── 订阅控制（来自官方 updateSubscriptions）──
  // 听众只订阅选定语言的音轨
  void _updateSubscriptions() {
    if (_room == null || widget.role != 'attendee') return;

    for (final participant in _room!.remoteParticipants.values) {
      final isOrganizer = participant.identity.startsWith('organizer-');
      final isSelectedTranslator =
          _translatorIdentity != null && participant.identity == _translatorIdentity;

      for (final pub in participant.trackPublications.values) {
        if (pub.kind == TrackType.AUDIO) {
          if (_currentLanguage == 'original') {
            // 原声：只订阅主讲人音轨
            (pub as RemoteTrackPublication).setSubscribed(isOrganizer);
          } else {
            // 翻译：只订阅对应 Bot 音轨
            (pub as RemoteTrackPublication).setSubscribed(isSelectedTranslator);
          }
        }
      }
    }
  }

  // ── Track 订阅事件 ──
  void _onTrackSubscribed(TrackSubscribedEvent event) {
    // LiveKit Flutter SDK 自动处理音频播放
    if (mounted) setState(() {});
  }

  void _onTrackUnsubscribed(TrackUnsubscribedEvent event) {
    if (mounted) setState(() {});
  }

  // ── 接收字幕数据（来自官方 RoomEvent.DataReceived）──
  void _onDataReceived(DataReceivedEvent event) {
    if (event.topic != 'transcription') return;
    try {
      final data = jsonDecode(utf8.decode(event.data));
      if (data['type'] != 'transcription') return;

      // 听众只显示自己选的语言
      if (widget.role == 'attendee' && data['language'] != _currentLanguage) return;

      if (!mounted) return;
      setState(() {
        final segmentId = data['segmentId'] as String;
        final text = data['text'] as String;
        final isFinal = data['final'] as bool? ?? false;

        final existing = _transcripts.indexWhere((t) => t.id == segmentId);
        if (existing >= 0) {
          _transcripts[existing].text += text;
          _transcripts[existing].isFinal = isFinal;
        } else {
          _transcripts.add(TranscriptEntry(id: segmentId, text: text, isFinal: isFinal));
        }

        // 最多保留 50 条
        if (_transcripts.length > 50) _transcripts.removeRange(0, _transcripts.length - 50);
      });
    } catch (_) {}
  }

  // ── 语言切换（来自官方 LanguageSelector handleChange）──
  Future<void> _changeLanguage(String langCode) async {
    if (_langSwitching) return;
    setState(() { _langSwitching = true; });

    final previousLanguage = _currentLanguage;

    // 取消上一个语言订阅
    if (previousLanguage != 'original' && previousLanguage != langCode) {
      try {
        await http.post(
          Uri.parse('$baseUrl/api/gemini/translate/unsubscribe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'sessionId': widget.sessionId, 'targetLanguage': previousLanguage}),
        );
      } catch (_) {}
    }

    if (langCode == 'original') {
      setState(() {
        _currentLanguage = 'original';
        _translatorIdentity = null;
        _transcripts.clear();
        _langSwitching = false;
      });
      _updateSubscriptions();
      return;
    }

    try {
      // 请求 Gemini Bot 启动（来自官方 POST /api/translate）
      final res = await http.post(
        Uri.parse('$baseUrl/api/gemini/translate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'sessionId': widget.sessionId,
          'targetLanguage': langCode,
          'previousLanguage': previousLanguage != 'original' ? previousLanguage : null,
        }),
      );

      if (res.statusCode != 200) throw Exception(res.body);
      final data = jsonDecode(res.body);

      setState(() {
        _currentLanguage = langCode;
        _translatorIdentity = data['translatorIdentity'];
        _transcripts.clear();
        _langSwitching = false;
      });

      _updateSubscriptions();
    } catch (e) {
      setState(() { _langSwitching = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('翻译启动失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ── 主讲人：轮询翻译状态 ──
  void _startTranslationsPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted || _room == null) return false;
      try {
        final res = await http.get(
          Uri.parse('$baseUrl/api/gemini/translate/status?sessionId=${widget.sessionId}'),
        );
        if (res.statusCode == 200 && mounted) {
          final data = jsonDecode(res.body);
          setState(() {
            _translations = List<Map<String, dynamic>>.from(data['translations'] ?? []);
          });
        }
      } catch (_) {}
      return mounted && _room != null;
    });
  }

  // ── 麦克风切换 ──
  Future<void> _toggleMic() async {
    _micEnabled = !_micEnabled;
    await _room?.localParticipant?.setMicrophoneEnabled(_micEnabled);
    if (mounted) setState(() {});
  }

  // ── 离开房间 ──
  Future<void> _leave() async {
    // 取消字幕订阅（来自官方 cleanup）
    if (widget.role == 'attendee' && _currentLanguage != 'original') {
      try {
        await http.post(
          Uri.parse('$baseUrl/api/gemini/translate/unsubscribe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'sessionId': widget.sessionId, 'targetLanguage': _currentLanguage}),
        );
      } catch (_) {}
    }

    // 主讲人结束时清理所有 Bridge（来自官方 DELETE /api/sessions/:id）
    if (widget.role == 'organizer') {
      try {
        await http.delete(Uri.parse('$baseUrl/api/gemini/sessions/${widget.sessionId}'));
      } catch (_) {}
    }

    _listener?.dispose();
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    final isOrganizer = widget.role == 'organizer';

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: _connecting
            ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                CircularProgressIndicator(color: Color(0xFF00E676)),
                SizedBox(height: 16),
                Text('连接中...', style: TextStyle(color: Color(0xFF666666))),
              ]))
            : Column(children: [
                // ── 状态栏 ──
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Row(children: [
                      Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF00E676), shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(_status, style: const TextStyle(color: Color(0xFF00E676), fontSize: 14, fontWeight: FontWeight.w600)),
                    ]),
                    Text(widget.sessionId, style: const TextStyle(color: Color(0xFF444444), fontSize: 12, fontFamily: 'monospace')),
                  ]),
                ),

                Expanded(child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

                    // ── 字幕区域 ──
                    const Text('翻译字幕', style: TextStyle(color: Color(0xFF666666), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 120, maxHeight: 200),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111111),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1A1A1A)),
                      ),
                      child: _transcripts.isEmpty
                          ? const Center(child: Text('等待说话...', style: TextStyle(color: Color(0xFF333333), fontSize: 14)))
                          : ListView.builder(
                              shrinkWrap: true,
                              reverse: true,
                              itemCount: _transcripts.length,
                              itemBuilder: (_, i) {
                                final t = _transcripts[_transcripts.length - 1 - i];
                                return Text(t.text, style: TextStyle(
                                  color: t.isFinal ? const Color(0xFFF0F0F0) : const Color(0xFF666666),
                                  fontSize: 15, height: 1.6,
                                ));
                              },
                            ),
                    ),

                    const SizedBox(height: 20),

                    // ── 语言选择器（听众）──
                    if (!isOrganizer) ...[
                      const Text('我想听', style: TextStyle(color: Color(0xFF666666), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF1A1A1A)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          DropdownButton<String>(
                            value: _currentLanguage,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF1A1A1A),
                            style: const TextStyle(color: Color(0xFFF0F0F0), fontSize: 15),
                            underline: const SizedBox(),
                            onChanged: _langSwitching ? null : (val) { if (val != null) _changeLanguage(val); },
                            items: const [
                              DropdownMenuItem(value: 'original', child: Text('🔊 原声')),
                              DropdownMenuItem(value: 'zh', child: Text('🇨🇳 中文')),
                              DropdownMenuItem(value: 'en', child: Text('🇺🇸 English')),
                              DropdownMenuItem(value: 'ja', child: Text('🇯🇵 日本語')),
                              DropdownMenuItem(value: 'ko', child: Text('🇰🇷 한국어')),
                              DropdownMenuItem(value: 'es', child: Text('🇪🇸 Español')),
                              DropdownMenuItem(value: 'fr', child: Text('🇫🇷 Français')),
                              DropdownMenuItem(value: 'de', child: Text('🇩🇪 Deutsch')),
                              DropdownMenuItem(value: 'pt', child: Text('🇧🇷 Português')),
                              DropdownMenuItem(value: 'ru', child: Text('🇷🇺 Русский')),
                              DropdownMenuItem(value: 'ar', child: Text('🇸🇦 العربية')),
                              DropdownMenuItem(value: 'hi', child: Text('🇮🇳 हिन्दी')),
                              DropdownMenuItem(value: 'th', child: Text('🇹🇭 ภาษาไทย')),
                              DropdownMenuItem(value: 'vi', child: Text('🇻🇳 Tiếng Việt')),
                              DropdownMenuItem(value: 'id', child: Text('🇮🇩 Indonesia')),
                            ],
                          ),
                          if (_langSwitching)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Row(children: [
                                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFD600))),
                                SizedBox(width: 8),
                                Text('启动翻译中...', style: TextStyle(color: Color(0xFFFFD600), fontSize: 13)),
                              ]),
                            )
                          else if (_currentLanguage != 'original')
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(children: [
                                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF00E676), shape: BoxShape.circle)),
                                const SizedBox(width: 6),
                                Text('翻译到 ${_currentLanguage.toUpperCase()} 已启动', style: const TextStyle(color: Color(0xFF00E676), fontSize: 13)),
                              ]),
                            ),
                        ]),
                      ),
                    ],

                    // ── 翻译列表（主讲人）──
                    if (isOrganizer) ...[
                      const Text('当前活跃翻译', style: TextStyle(color: Color(0xFF666666), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF1A1A1A)),
                        ),
                        child: _translations.isEmpty
                            ? const Text('暂无听众请求翻译', style: TextStyle(color: Color(0xFF333333), fontSize: 14))
                            : Column(children: _translations.map((t) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                  Text((t['language'] as String).toUpperCase(), style: const TextStyle(color: Color(0xFFF0F0F0), fontSize: 14, fontWeight: FontWeight.w600)),
                                  Text('${t['subscriberCount']} 人 · ${t['status']}', style: const TextStyle(color: Color(0xFF666666), fontSize: 12)),
                                ]),
                              )).toList()),
                      ),
                    ],

                    const SizedBox(height: 24),
                  ]),
                )),

                // ── 控制栏 ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Row(children: [
                    if (isOrganizer) ...[
                      GestureDetector(
                        onTap: _toggleMic,
                        child: Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(
                            color: _micEnabled ? const Color(0xFF1A1A1A) : const Color(0xFFEF4444),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_micEnabled ? Icons.mic : Icons.mic_off, color: Colors.white, size: 24),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: ElevatedButton(
                      onPressed: _leave,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('结束通话', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    )),
                  ]),
                ),
              ]),
      ),
    );
  }
}
