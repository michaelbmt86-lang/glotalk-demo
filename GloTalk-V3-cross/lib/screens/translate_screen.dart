// 参考来源：
//   https://pub.dev/packages/record (v6.2.0) — AudioRecorder.startStream() → Stream<Uint8List>
//   https://docs.flutter.dev/cookbook/audio/record (Flutter 官方文档 2026-05-05)
//   https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter-examples/streaming_asr/lib/streaming_asr.dart
//   工作手册 V16「数据流架构」— VAD → STT → 翻译 → TTS 串联流水线
//
// 修正 #5：用 record ^6.0.0 真实 PCM 流替换占位 StreamController
//   record 包 startStream() 输出 Stream<Uint8List>，编码为 pcm16bits（Int16LE）
//   需转换：Uint8List → Int16List → Float32List（÷ 32768.0）再喂给 VAD

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';           // ← record ^6.0.0
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../services/stt_service.dart';
import '../services/translator_service.dart';
import '../services/tts_service.dart';

class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key});

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  // ── 三个服务 ──────────────────────────────────────────────────────────
  final SttService _stt = SttService();
  final TranslatorService _translator = TranslatorService();
  final TtsService _tts = TtsService();

  // ── record 包（修正 #5：真实麦克风 PCM 流）────────────────────────────
  // 来源：https://pub.dev/packages/record AudioRecorder API
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSubscription;

  // ── 状态 ──────────────────────────────────────────────────────────────
  bool _isInitializing = true;
  String _initError = '';
  bool _isListening = false;
  bool _isPipelineBusy = false;

  // ── UI 数据 ───────────────────────────────────────────────────────────
  String _sourceText = '';
  String _translatedText = '';

  // ── 调试面板 ──────────────────────────────────────────────────────────
  bool _showDebug = false;
  List<int> _lastEncoderTokenIds = [];
  List<int> _lastDecoderTokenIds = [];
  final StringBuffer _debugBuf = StringBuffer();
  String _debugLog = '';

  // ── VAD ───────────────────────────────────────────────────────────────
  sherpa_onnx.VoiceActivityDetector? _vad;
  bool _vadSpeechDetected = false;
  final List<double> _audioBuffer = [];
  static const int _kSampleRate = 16000;
  // record 包每回调块大小约 4096 bytes = 2048 Int16 samples（~128ms）
  // VAD 以 Float32 帧为单位，此处直接逐块处理
  static const int _kSilenceFramesThreshold = 5; // ~640ms 静音触发

  int _silenceFrameCount = 0;

  @override
  void initState() {
    super.initState();
    _initPipeline();
  }

  // ─────────────────────────────────────────────────────────────────────
  // 初始化
  // ─────────────────────────────────────────────────────────────────────
  Future<void> _initPipeline() async {
    try {
      // 权限检查由 record 包内部处理（hasPermission()）
      _appendDebug('检查麦克风权限...');
      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) throw Exception('麦克风权限被拒绝');

      _appendDebug('加载 SenseVoice STT...');
      await _stt.initialize();           // initBindings() 在内部第一行
      _appendDebug('STT ✅');

      _appendDebug('加载 Opus-MT 翻译...');
      await _translator.initialize();
      _appendDebug('翻译 ✅');

      _appendDebug('加载 VITS Piper TTS...');
      await _tts.initialize();
      _appendDebug('TTS ✅  sampleRate=${_tts.sampleRate}');

      await _initVad();
      _appendDebug('VAD ✅');

      setState(() => _isInitializing = false);
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _initError = e.toString();
      });
    }
  }

  Future<void> _initVad() async {
    // 来源：https://k2-fsa.github.io/sherpa/onnx/vad/index.html
    final sileroConfig = sherpa_onnx.SileroVadModelConfig(
      model: 'assets/models/vad/silero_vad.onnx',
      threshold: 0.5,
      minSilenceDuration: 0.5,
      minSpeechDuration: 0.25,
      windowSize: 512,
    );
    final vadConfig = sherpa_onnx.VadModelConfig(
      sileroVad: sileroConfig,
      sampleRate: _kSampleRate,
      numThreads: 1,
      debug: false,
    );
    _vad = sherpa_onnx.VoiceActivityDetector(
      config: vadConfig,
      bufferSizeInSeconds: 30,
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // 录音控制（修正 #5：真实 record PCM 流）
  // ─────────────────────────────────────────────────────────────────────
  Future<void> _toggleListening() async {
    if (_isListening) {
      await _stopListening();
    } else {
      await _startListening();
    }
  }

  Future<void> _startListening() async {
    setState(() => _isListening = true);
    _audioBuffer.clear();
    _silenceFrameCount = 0;
    _vadSpeechDetected = false;

    // 来源：https://pub.dev/packages/record
    //   record.startStream(RecordConfig(encoder: AudioEncoder.pcm16bits))
    //   → Stream<Uint8List>（signed Int16 Little-Endian，单声道，16000 Hz）
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _kSampleRate,
        numChannels: 1,
        // 关闭自动增益和噪声抑制，由 VAD 自主处理
        autoGain: false,
        noiseSuppress: false,
        echoCancel: true,
      ),
    );

    // 订阅 Stream<Uint8List>，转换为 Float32 后喂给 VAD
    _pcmSubscription = stream.listen(_onPcmChunk);
  }

  Future<void> _stopListening() async {
    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    await _recorder.stop();
    setState(() => _isListening = false);

    // 把剩余缓冲区最后一段送 STT
    if (_audioBuffer.isNotEmpty && _vadSpeechDetected) {
      _runPipeline(List<double>.from(_audioBuffer));
      _audioBuffer.clear();
    }
  }

  /// record 包回调：Uint8List（Int16LE PCM）→ Float32 → VAD
  /// 来源：https://pub.dev/packages/record
  ///   StreamConfig(encoder: AudioEncoder.pcm16bits) 输出为 Int16 LE
  void _onPcmChunk(Uint8List rawBytes) {
    if (_vad == null) return;

    // Int16LE → Float32List（[-1.0, 1.0]）
    final int16 = rawBytes.buffer.asInt16List(
      rawBytes.offsetInBytes,
      rawBytes.lengthInBytes ~/ 2,
    );
    final float32 = Float32List(int16.length);
    for (int i = 0; i < int16.length; i++) {
      float32[i] = int16[i] / 32768.0;
    }

    _processVadFrame(float32);
  }

  /// VAD 异步流水线（与上一版逻辑相同，此处接收真实 Float32 帧）
  void _processVadFrame(Float32List frame) {
    _vad!.acceptWaveform(frame);
    final hasSpeech = !_vad!.isEmpty();

    if (hasSpeech) {
      _vadSpeechDetected = true;
      _silenceFrameCount = 0;
      _audioBuffer.addAll(frame);
    } else {
      if (_vadSpeechDetected) {
        _silenceFrameCount++;
        _audioBuffer.addAll(frame); // 保留少量静音尾巴防止截断
        if (_silenceFrameCount >= _kSilenceFramesThreshold) {
          _vadSpeechDetected = false;
          _silenceFrameCount = 0;
          final segment = List<double>.from(_audioBuffer);
          _audioBuffer.clear();
          _runPipeline(segment);
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 三阶段流水线：STT → 翻译 → TTS
  // ─────────────────────────────────────────────────────────────────────
  Future<void> _runPipeline(List<double> samples) async {
    if (_isPipelineBusy) return;
    setState(() => _isPipelineBusy = true);

    try {
      // Stage 1: SenseVoice STT
      _appendDebug('[STT] ${samples.length} samples');
      final srcText = await _stt.recognize(samples);
      if (srcText.isEmpty) { _appendDebug('[STT] 空结果'); return; }
      setState(() => _sourceText = srcText);
      _appendDebug('[STT] ✅ "$srcText"');

      // Stage 2: Opus-MT 翻译
      _appendDebug('[翻译] 开始...');
      final result = await _translator.translate(srcText);
      setState(() {
        _translatedText = result.translatedText;
        _lastEncoderTokenIds = result.encoderTokenIds;
        _lastDecoderTokenIds = result.decoderTokenIds;
      });
      _appendDebug('[翻译] ✅ "${result.translatedText}"');
      _appendDebug('[enc] ${result.encoderTokenIds.take(12)}...');
      _appendDebug('[dec] ${result.decoderTokenIds.take(12)}...');

      // Stage 3: VITS Piper TTS
      _appendDebug('[TTS] 合成...');
      final audio = await _tts.generate(result.translatedText);
      _appendDebug('[TTS] ✅ ${audio.samples.length} @ ${audio.sampleRate}Hz');
      // TODO: 接入 flutter_sound / audioplayers 播放 audio.samples
    } catch (e) {
      _appendDebug('[❌] $e');
    } finally {
      setState(() => _isPipelineBusy = false);
    }
  }

  void _appendDebug(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _debugBuf.writeln('$ts  $msg');
    // 只保留最新 40 行
    final lines = _debugBuf.toString().split('\n');
    if (lines.length > 42) {
      _debugBuf.clear();
      _debugBuf.writeAll(lines.skip(lines.length - 40), '\n');
    }
    setState(() => _debugLog = _debugBuf.toString());
  }

  @override
  void dispose() {
    _pcmSubscription?.cancel();
    _recorder.dispose();   // record 包要求 dispose
    _vad?.free();
    _stt.dispose();
    _translator.dispose();
    _tts.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isInitializing) return _buildLoading();
    if (_initError.isNotEmpty) return _buildError();
    return _buildMain();
  }

  Widget _buildLoading() => const Scaffold(
        backgroundColor: Color(0xFF121212),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF1A73E8)),
              SizedBox(height: 16),
              Text('正在加载离线模型...', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );

  Widget _buildError() => Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '初始化失败：\n$_initError',
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );

  Widget _buildMain() => Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: const Text('GloTalk V3 — 离线跨语言'),
          backgroundColor: const Color(0xFF1E1E1E),
          actions: [
            IconButton(
              icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
              onPressed: () => setState(() => _showDebug = !_showDebug),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_isPipelineBusy)
              const LinearProgressIndicator(
                  backgroundColor: Color(0xFF333333), color: Color(0xFF1A73E8)),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SpeechBubble(
                    label: '识别（中文）',
                    text: _sourceText.isEmpty ? '等待说话...' : _sourceText,
                    color: const Color(0xFF1A3A5C),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.arrow_downward, color: Color(0xFF1A73E8)),
                      SizedBox(width: 8),
                      Text('Opus-MT', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SpeechBubble(
                    label: '翻译（英文）',
                    text: _translatedText.isEmpty ? '等待翻译...' : _translatedText,
                    color: const Color(0xFF1A4A2A),
                  ),
                  const SizedBox(height: 24),
                  if (_showDebug) _buildDebugPanel(),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: GestureDetector(
                onTap: _toggleListening,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening ? Colors.redAccent : const Color(0xFF1A73E8),
                    boxShadow: _isListening
                        ? [const BoxShadow(color: Colors.red, blurRadius: 20, spreadRadius: 4)]
                        : [],
                  ),
                  child: Icon(
                    _isListening ? Icons.stop : Icons.mic,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildDebugPanel() => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: const Color(0xFF333333)),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🐛 调试面板',
                style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
            const Divider(color: Color(0xFF333333)),
            const Text('Encoder token ids (前20):',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            Text(
              _lastEncoderTokenIds.isEmpty ? '（空）' : _lastEncoderTokenIds.take(20).join(', '),
              style: const TextStyle(
                  color: Colors.cyanAccent, fontSize: 11, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 6),
            const Text('Decoder token ids (前20):',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            Text(
              _lastDecoderTokenIds.isEmpty ? '（空）' : _lastDecoderTokenIds.take(20).join(', '),
              style: const TextStyle(
                  color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
            ),
            const Divider(color: Color(0xFF333333)),
            const Text('日志:', style: TextStyle(color: Colors.white54, fontSize: 11)),
            Text(
              _debugLog.isEmpty ? '（无）' : _debugLog,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
              maxLines: 20,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
}

// ── 辅助 Widget ─────────────────────────────────────────────────────────
class _SpeechBubble extends StatelessWidget {
  final String label;
  final String text;
  final Color color;
  const _SpeechBubble({required this.label, required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 6),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      );
}
