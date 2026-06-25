// lib/services/tts_service.dart
//
// TTS 引擎：sherpa-onnx VITS Piper English
//   模型：vits-piper-en_US-libritts_r-medium（Apache 2.0）
//   用途：将英文翻译结果朗读出来，发给对方
//
// 架构参考：
//   官方 Flutter TTS 示例
//   https://github.com/k2-fsa/sherpa-onnx/tree/master/flutter-examples/tts
//   官方 Python offline-tts.py（VitsModelConfig 字段定义）
//   https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/offline-tts.py
//
// 输出：Float32 PCM，24000 Hz，单声道
// 与 LiveKit 对接：将 Float32 PCM 推入 LocalAudioTrack 发布到房间
// 已知问题（Issue #2679）：中文 VITS 模型在 iOS Flutter 下有 bug；
//   我们只用英文 Piper 模型（已验证 iOS/Android 均正常）

import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// TTS 合成完成后的回调
/// [pcm] Float32List，采样率 24000Hz，单声道
/// [sampleRate] 实际采样率（由模型决定，通常 22050 或 24000）
typedef TtsCallback = void Function(Float32List pcm, int sampleRate);

class TtsService {
  // ─── 单例 ──────────────────────────────────────────────────
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  // ─── 内部状态 ──────────────────────────────────────────────
  bool _initialized = false;
  late sherpa.OfflineTts _tts;

  // ─── 初始化 ────────────────────────────────────────────────
  Future<void> initialize() async {
    if (_initialized) return;

    final docsDir = await getApplicationDocumentsDirectory();
    final modelDir = '${docsDir.path}/vits-piper-en';

    // 将模型文件从 assets 复制到磁盘
    // （sherpa_onnx 需要本地文件路径）
    await _extractAssetIfNeeded(
      'assets/models/vits-piper-en/en_US-libritts_r-medium.onnx',
      '$modelDir/en_US-libritts_r-medium.onnx',
    );
    await _extractAssetIfNeeded(
      'assets/models/vits-piper-en/en_US-libritts_r-medium.onnx.json',
      '$modelDir/en_US-libritts_r-medium.onnx.json',
    );
    await _extractAssetIfNeeded(
      'assets/models/vits-piper-en/tokens.txt',
      '$modelDir/tokens.txt',
    );
    // espeak-ng-data 是目录，需要递归复制
    await _extractEspeakData(modelDir);

    // 构建 OfflineTts（VITS + Piper）
    // 字段参考：官方 Python API OfflineTtsVitsModelConfig
    final vitsConfig = sherpa.OfflineTtsVitsModelConfig(
      model: '$modelDir/en_US-libritts_r-medium.onnx',
      lexicon: '',         // Piper 模型使用 espeak-ng，不需要 lexicon.txt
      tokens: '$modelDir/tokens.txt',
      dataDir: '$modelDir/espeak-ng-data',  // Piper 依赖 espeak-ng 做 G2P
      noiseScale: 0.667,
      noiseScaleW: 0.8,
      lengthScale: 1.0,    // 语速（1.0 = 正常）
    );

    final modelConfig = sherpa.OfflineTtsModelConfig(
      vits: vitsConfig,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    );

    final ttsConfig = sherpa.OfflineTtsConfig(
      model: modelConfig,
      ruleFsts: '',          // 英文 Piper 不需要额外规则
      maxNumSentences: 1,
    );

    _tts = sherpa.OfflineTts(ttsConfig);
    _initialized = true;
  }

  // ─── 合成英文文字 → PCM ────────────────────────────────────
  /// 将英文 [text] 合成为 Float32 PCM 音频并通过 [onDone] 回调返回。
  /// [speakerId] 对于 libritts_r-medium 有效范围 0–903（默认 0）。
  /// [speed] 语速倍率，1.0 = 正常。
  Future<void> synthesize({
    required String text,
    required TtsCallback onDone,
    int speakerId = 0,
    double speed = 1.0,
  }) async {
    if (!_initialized) {
      throw StateError('TtsService: 请先调用 initialize()');
    }
    if (text.trim().isEmpty) return;

    // sherpa_onnx Dart API：generate(text, sid, speed)
    // 返回 GeneratedAudio { samples: Float32List, sampleRate: int }
    final audio = _tts.generate(
      text: text,
      sid: speakerId,
      speed: speed,
    );

    if (audio.samples.isEmpty) {
      // 空音频通常是文字处理问题，记录并跳过
      assert(false, 'TtsService: generate() 返回空样本，text="$text"');
      return;
    }

    onDone(audio.samples, audio.sampleRate);
  }

  // ─── 同步合成（返回 PCM 数据，供调用方自行处理）─────────────
  /// 返回 [GeneratedAudio]，包含 samples（Float32List）和 sampleRate。
  /// 适合需要自行处理 PCM 数据的场景（如推入 LiveKit 自定义音轨）。
  sherpa.OfflineTtsGeneratedAudio generateSync({
    required String text,
    int speakerId = 0,
    double speed = 1.0,
  }) {
    if (!_initialized) {
      throw StateError('TtsService: 请先调用 initialize()');
    }
    return _tts.generate(
      text: text,
      sid: speakerId,
      speed: speed,
    );
  }

  // ─── Assets → 磁盘（单文件）──────────────────────────────
  Future<void> _extractAssetIfNeeded(String assetPath, String destPath) async {
    final file = File(destPath);
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    final data = await rootBundle.load(assetPath);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }

  // ─── Assets → 磁盘（espeak-ng-data 目录）─────────────────
  // Flutter assets 无法直接列举目录，需要使用 AssetManifest 获取文件列表
  Future<void> _extractEspeakData(String modelDir) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest.listAssets().where(
      (k) => k.startsWith('assets/models/vits-piper-en/espeak-ng-data/'),
    );

    for (final assetKey in keys) {
      final relativePath = assetKey.replaceFirst(
        'assets/models/vits-piper-en/',
        '',
      );
      final destPath = '$modelDir/$relativePath';
      await _extractAssetIfNeeded(assetKey, destPath);
    }
  }

  // ─── 释放资源 ──────────────────────────────────────────────
  void dispose() {
    if (_initialized) {
      _tts.free();
      _initialized = false;
    }
  }
}
