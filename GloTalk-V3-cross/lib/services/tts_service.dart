// 参考来源：
//   https://pub.dev/documentation/sherpa_onnx/latest/sherpa_onnx/OfflineTts-class.html
//   https://k2-fsa.github.io/sherpa/onnx/tts/all/English/vits-piper-en_US-ryan-medium.html
//   https://api.flutter.dev/flutter/services/AssetManifest-class.html
//     — AssetManifest.loadFromAssetBundle(rootBundle) → .assets() 返回所有 asset key
//   工作手册 V16「模型文件」— vits-piper-en_US-libritts_r-medium (Apache 2.0)
//
// 修正 #4：_extractEspeakData() 必须用 AssetManifest 遍历
//   espeak-ng-data/ 下所有文件并逐一复制到本地目录，不能只建空目录
//   原因：sherpa_onnx Piper TTS C++ 层在运行时会按需读取 espeak-ng-data/ 里的各个文件
//         （phontab, phondata, phonindex, intonations, *.lg 等），目录为空则 TTS 输出静音

import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'dart:io';

class TtsService {
  sherpa_onnx.OfflineTts? _tts;
  bool _initialized = false;

  int get sampleRate => _tts?.sampleRate ?? 22050;

  // Asset 路径前缀（与 pubspec.yaml assets 声明一致）
  static const String _kAssetBase =
      'assets/models/tts/vits-piper-en_US-libritts_r-medium';
  static const String _kModelFile = 'en_US-libritts_r-medium.onnx';
  static const String _kTokensFile = 'tokens.txt';
  static const String _kEspeakSubdir = 'espeak-ng-data';

  Future<void> initialize() async {
    // sherpa_onnx.initBindings() 可安全重复调用（幂等）
    sherpa_onnx.initBindings();
    if (_initialized) return;

    final modelPath = await _extractSingleAsset('$_kAssetBase/$_kModelFile');
    final tokensPath = await _extractSingleAsset('$_kAssetBase/$_kTokensFile');

    // 修正 #4：用 AssetManifest 遍历 espeak-ng-data/ 下所有文件，逐一写入本地目录
    // 来源：https://api.flutter.dev/flutter/services/AssetManifest-class.html
    //   AssetManifest.loadFromAssetBundle(rootBundle) → .assets() → List<String>
    final dataDirPath = await _extractEspeakData();

    // 构造 VITS Piper 配置
    // 来源：https://k2-fsa.github.io/sherpa/onnx/tts/all/English/vits-piper-en_US-ryan-medium.html
    final vitsConfig = sherpa_onnx.OfflineTtsVitsModelConfig(
      model: modelPath,
      tokens: tokensPath,
      dataDir: dataDirPath,  // espeak-ng-data 完整目录路径
      lexicon: '',           // Piper 英文模型不需要 lexicon
    );

    final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
      vits: vitsConfig,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    );

    // ✅ 规范：OfflineTtsConfig 不传入任何 maxNumSentences / maxNumSenetences 参数
    // 来源：工作手册 V16 tts_service.dart 要求
    final config = sherpa_onnx.OfflineTtsConfig(
      model: modelConfig,
    );

    _tts = sherpa_onnx.OfflineTts(config);
    _initialized = true;
  }

  /// 合成英文文字为音频
  /// 返回 GeneratedAudio（来源：pub.dev/documentation/sherpa_onnx/latest/sherpa_onnx/OfflineTts-class.html）
  ///   GeneratedAudio.samples → Float32List
  ///   GeneratedAudio.sampleRate → int
  Future<sherpa_onnx.GeneratedAudio> generate(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    assert(_initialized, 'TtsService: 必须先调用 initialize()');
    return _tts!.generate(text: text, sid: sid, speed: speed);
  }

  // ─────────────────────────────────────────────────────────────────────
  // 修正 #4：AssetManifest 遍历 espeak-ng-data/ 下所有文件
  // ─────────────────────────────────────────────────────────────────────
  /// 将 espeak-ng-data/ 目录下的所有 asset 文件提取到本地缓存目录。
  /// 返回本地目录路径（传给 OfflineTtsVitsModelConfig.dataDir）。
  ///
  /// Flutter AssetManifest API：
  ///   来源：https://api.flutter.dev/flutter/services/AssetManifest-class.html
  ///   AssetManifest.loadFromAssetBundle(rootBundle).assets()
  ///   → Iterable<String> — 所有已声明 asset 的 key（即 pubspec.yaml 里的路径）
  Future<String> _extractEspeakData() async {
    final cacheDir = await getApplicationCacheDirectory();
    final localDataDir =
        Directory('${cacheDir.path}/glotalk_tts/$_kAssetBase/$_kEspeakSubdir');

    // 加载 AssetManifest，遍历所有属于 espeak-ng-data/ 的 asset key
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final allAssets = manifest.listAssets(); // Flutter >=3.2 API
    final espeakAssets = allAssets.where(
      (key) => key.startsWith('$_kAssetBase/$_kEspeakSubdir/'),
    );

    for (final assetKey in espeakAssets) {
      // 计算相对路径：去掉 "assets/models/tts/.../espeak-ng-data/" 前缀
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

  /// 提取单个 asset 文件到本地缓存（model.onnx、tokens.txt）
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
