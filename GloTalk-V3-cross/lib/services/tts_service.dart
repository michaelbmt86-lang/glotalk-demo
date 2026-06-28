// 参考来源：
//   https://pub.dev/documentation/sherpa_onnx/latest/sherpa_onnx/OfflineTts-class.html
//   https://k2-fsa.github.io/sherpa/onnx/tts/all/English/vits-piper-en_US-ryan-medium.html
//   https://api.flutter.dev/flutter/services/AssetManifest-class.html

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'dart:io';

class TtsService {
  sherpa_onnx.OfflineTts? _tts;
  bool _initialized = false;

  int get sampleRate => _tts?.sampleRate ?? 22050;

  static const String _kAssetBase =
      'assets/models/tts/vits-piper-en_US-libritts_r-medium';
  static const String _kModelFile = 'en_US-libritts_r-medium.onnx';
  static const String _kTokensFile = 'tokens.txt';
  static const String _kEspeakSubdir = 'espeak-ng-data';

  Future<void> initialize() async {
    sherpa_onnx.initBindings();
    if (_initialized) return;

    final modelPath = await _extractSingleAsset('$_kAssetBase/$_kModelFile');
    final tokensPath = await _extractSingleAsset('$_kAssetBase/$_kTokensFile');
    final dataDirPath = await _extractEspeakData();

    final vitsConfig = sherpa_onnx.OfflineTtsVitsModelConfig(
      model: modelPath,
      tokens: tokensPath,
      dataDir: dataDirPath,
      lexicon: '',
    );

    final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
      vits: vitsConfig,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    );

    final config = sherpa_onnx.OfflineTtsConfig(
      model: modelConfig,
    );

    _tts = sherpa_onnx.OfflineTts(config);
    _initialized = true;
  }

  Future<sherpa_onnx.GeneratedAudio> generate(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    assert(_initialized, 'TtsService: 必须先调用 initialize()');
    return _tts!.generate(text: text, sid: sid, speed: speed);
  }

  Future<String> _extractEspeakData() async {
    final cacheDir = await getApplicationCacheDirectory();
    final localDataDir =
        Directory('${cacheDir.path}/glotalk_tts/$_kAssetBase/$_kEspeakSubdir');

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final allAssets = manifest.listAssets();
    final espeakAssets = allAssets.where(
      (key) => key.startsWith('$_kAssetBase/$_kEspeakSubdir/'),
    );

    for (final assetKey in espeakAssets) {
      final relativePath =
          assetKey.substring('$_kAssetBase/$_kEspeakSubdir/'.length);
      final localFile = File('${localDataDir.path}/$relativePath');

      if (!localFile.existsSync()) {
        await localFile.parent.create(recursive: true);
        final data = await rootBundle.load(assetKey);
        await localFile.writeAsBytes(data.buffer.asUint8List());
      }
    }

    return localDataDir.path;
  }

  Future<String> _extractSingleAsset(String assetPath) async {
    final cacheDir = await getApplicationCacheDirectory();
    final relativePath = assetPath.replaceFirst('assets/models/tts/', '');
    final localFile = File('${cacheDir.path}/glotalk_tts/$relativePath');

    if (!localFile.existsSync()) {
      await localFile.parent.create(recursive: true);
      final data = await rootBundle.load(assetPath);
      await localFile.writeAsBytes(data.buffer.asUint8List());
    }
    return localFile.path;
  }

  void dispose() {
    _tts?.free();
    _tts = null;
    _initialized = false;
  }
}
