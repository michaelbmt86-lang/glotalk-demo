// lib/services/stt_service.dart
//
// STT 引擎：sherpa-onnx SenseVoice int8
//   模型：sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8
//   支持语言：中文、英文、日文、韩文、粤语（自动检测）
//   协议：Apache 2.0
//
// 架构参考：
//   官方 Flutter 示例 streaming_asr.dart
//   https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter-examples/streaming_asr/lib/streaming_asr.dart
//   官方 SenseVoice Dart API 文档
//   https://k2-fsa.github.io/sherpa/onnx/sense-voice/dart-api.html
//
// 模式：非流式（OfflineRecognizer + SenseVoice），每次 VAD 切割后送整段 PCM
// 采样率：16000 Hz，单声道，16-bit PCM → Float32
//
// 使用 record 包采集麦克风，存入 Float32 缓冲区，
// 检测到静音（能量低于阈值）后触发识别，通过回调输出文字。

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'dart:io';

/// STT 回调：每次识别完成时调用，传入识别文字和是否为最终结果
typedef SttCallback = void Function(String text, bool isFinal);

class SttService {
  // ─── 单例 ──────────────────────────────────────────────────
  static final SttService _instance = SttService._internal();
  factory SttService() => _instance;
  SttService._internal();

  // ─── 内部状态 ──────────────────────────────────────────────
  bool _initialized = false;
  late sherpa.OfflineRecognizer _recognizer;
  late AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _audioSub;

  // 音频缓冲（Float32，16kHz）
  final List<double> _audioBuffer = [];

  // VAD 简易参数
  static const int _sampleRate = 16000;
  static const int _silenceFrames = 30;   // 300ms 静音触发识别（30 * 10ms帧）
  static const double _silenceThreshold = 0.01; // RMS 阈值
  int _silenceCount = 0;

  SttCallback? _onResult;

  // ─── 初始化 ────────────────────────────────────────────────
  /// [modelDir] 为 assets 中模型目录（会被复制到应用文档目录）
  Future<void> initialize() async {
    if (_initialized) return;

    // 将 assets 中的模型文件复制到磁盘
    // sherpa_onnx 需要文件系统路径（不支持直接读 asset 字节）
    final docsDir = await getApplicationDocumentsDirectory();
    final modelDir = '${docsDir.path}/sense-voice';

    await _extractAssetIfNeeded(
      'assets/models/sense-voice/model.int8.onnx',
      '$modelDir/model.int8.onnx',
    );
    await _extractAssetIfNeeded(
      'assets/models/sense-voice/tokens.txt',
      '$modelDir/tokens.txt',
    );

    // 构建 OfflineRecognizer（SenseVoice 模式）
    // 参考：sherpa-onnx Dart API 文档 SenseVoice 节
    final senseVoiceConfig = sherpa.OfflineSenseVoiceModelConfig(
      model: '$modelDir/model.int8.onnx',
      language: '',        // 空字符串 = 自动检测（zh/en/ja/ko/yue）
      useInverseTextNormalization: 1,
    );

    final modelConfig = sherpa.OfflineModelConfig(
      senseVoice: senseVoiceConfig,
      tokens: '$modelDir/tokens.txt',
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    );

    final config = sherpa.OfflineRecognizerConfig(
      model: modelConfig,
    );

    _recognizer = sherpa.OfflineRecognizer(config);
    _recorder = AudioRecorder();
    _initialized = true;
  }

  // ─── 开始监听麦克风 ────────────────────────────────────────
  Future<void> startListening(SttCallback onResult) async {
    if (!_initialized) {
      throw StateError('SttService: 请先调用 initialize()');
    }
    _onResult = onResult;
    _audioBuffer.clear();
    _silenceCount = 0;

    // record 包：以 PCM 16-bit 16kHz 流的方式采集
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        bitRate: 256000,
      ),
    );

    _audioSub = stream.listen(_onAudioChunk);
  }

  // ─── 停止监听 ──────────────────────────────────────────────
  Future<void> stopListening() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    // 将剩余缓冲区送识别
    if (_audioBuffer.isNotEmpty) {
      _recognize(List.from(_audioBuffer));
      _audioBuffer.clear();
    }
  }

  // ─── 处理每个 PCM 块 ──────────────────────────────────────
  void _onAudioChunk(Uint8List bytes) {
    // PCM 16-bit little-endian → Float32 归一化到 [-1, 1]
    final samples = _pcm16ToFloat32(bytes);

    _audioBuffer.addAll(samples);

    // 简易 VAD：计算当前块 RMS
    double rms = 0;
    for (final s in samples) {
      rms += s * s;
    }
    rms = samples.isEmpty ? 0 : (rms / samples.length);

    if (rms < _silenceThreshold * _silenceThreshold) {
      _silenceCount++;
    } else {
      _silenceCount = 0;
    }

    // 连续静音超过阈值 → 触发识别
    if (_silenceCount >= _silenceFrames && _audioBuffer.length > _sampleRate ~/ 4) {
      final chunk = List<double>.from(_audioBuffer);
      _audioBuffer.clear();
      _silenceCount = 0;
      _recognize(chunk);
    }

    // 防止缓冲区过长（最多 10 秒）
    if (_audioBuffer.length > _sampleRate * 10) {
      final chunk = List<double>.from(_audioBuffer);
      _audioBuffer.clear();
      _recognize(chunk);
    }
  }

  // ─── 调用 sherpa_onnx 离线识别 ────────────────────────────
  void _recognize(List<double> samples) {
    if (samples.isEmpty) return;

    final stream = _recognizer.createStream();
    stream.acceptWaveform(
      samples: Float32List.fromList(samples),
      sampleRate: _sampleRate,
    );
    _recognizer.decode(stream);
    final result = _recognizer.getResult(stream);
    stream.free();

    final text = result.text.trim();
    if (text.isNotEmpty) {
      _onResult?.call(text, true);
    }
  }

  // ─── PCM 16-bit → Float32 ─────────────────────────────────
  List<double> _pcm16ToFloat32(Uint8List bytes) {
    final samples = <double>[];
    // 每两个字节构成一个 int16 样本（little-endian）
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      final lo = bytes[i];
      final hi = bytes[i + 1];
      int sample = lo | (hi << 8);
      // 符号扩展（int16）
      if (sample >= 0x8000) sample -= 0x10000;
      samples.add(sample / 32768.0);
    }
    return samples;
  }

  // ─── Assets → 磁盘 ────────────────────────────────────────
  Future<void> _extractAssetIfNeeded(String assetPath, String destPath) async {
    final file = File(destPath);
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    final data = await rootBundle.load(assetPath);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }

  // ─── 释放资源 ──────────────────────────────────────────────
  Future<void> dispose() async {
    await stopListening();
    if (_initialized) {
      _recognizer.free();
      _initialized = false;
    }
  }
}
