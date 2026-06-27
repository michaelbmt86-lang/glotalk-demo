// 参考来源：
//   https://pub.dev/packages/sherpa_onnx (v1.13.2)
//   https://k2-fsa.github.io/sherpa/onnx/sense-voice/dart-api.html
//   https://github.com/k2-fsa/sherpa-onnx/blob/master/dart-api-examples/non-streaming-asr/bin/sense-voice.dart
//   Go API 确认：type OfflineSenseVoiceModelConfig struct { Language string; UseInverseTextNormalization int }
//   (来源：https://pkg.go.dev/github.com/k2-fsa/sherpa-onnx/scripts/go)
//
// 修正 #2：
//   language → '' (空字符串 = auto，官方 Dart 示例用法)
//   useInverseTextNormalization → 1 (int 类型，对应 Go/C++ 层的 int，Dart 参数同类型)

import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'dart:io';

class SttService {
  sherpa_onnx.OfflineRecognizer? _recognizer;
  bool _initialized = false;

  static const String _kModelDir =
      'assets/models/stt/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8';
  static const String _kModelFile = 'model.int8.onnx';
  static const String _kTokensFile = 'tokens.txt';

  /// 初始化 SenseVoice 离线识别器
  /// ⚠️ initBindings() 必须是本方法第一行，不得挪到 main() 或任何其他地方
  /// 来源：pub.dev/packages/sherpa_onnx 文档
  Future<void> initialize() async {
    // ✅ 第一行：sherpa_onnx FFI 绑定初始化
    sherpa_onnx.initBindings();

    if (_initialized) return;

    final modelPath = await _extractAsset('$_kModelDir/$_kModelFile');
    final tokensPath = await _extractAsset('$_kModelDir/$_kTokensFile');

    // 修正 #2a：language 改为 '' (空字符串 = 自动检测)
    //   官方 dart 示例：language: language（从命令行参数读取，默认 'auto' 或 ''）
    //   来源：https://github.com/k2-fsa/sherpa-onnx/blob/master/dart-api-examples/non-streaming-asr/bin/sense-voice.dart
    //   'auto' 与 '' 均被 sherpa_onnx C++ 层接受，'' 更安全
    //
    // 修正 #2b：useInverseTextNormalization 改为 int 类型值 1
    //   来源：Go API struct { UseInverseTextNormalization int }
    //   Dart 层 API 镜像 C++ 层，参数类型为 int，1=开启 ITN，0=关闭
    final senseVoiceConfig = sherpa_onnx.OfflineSenseVoiceModelConfig(
      model: modelPath,
      language: '',                      // ✅ 修正 #2a：空字符串 = auto
      useInverseTextNormalization: true,    // ✅ 修正 #2b：int 类型，true=开启
    );

    final modelConfig = sherpa_onnx.OfflineModelConfig(
      senseVoice: senseVoiceConfig,
      tokens: tokensPath,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    );

    final config = sherpa_onnx.OfflineRecognizerConfig(
      model: modelConfig,
      decodingMethod: 'greedy_search',
    );

    _recognizer = sherpa_onnx.OfflineRecognizer(config);
    _initialized = true;
  }

  /// 识别音频
  /// [samples]：16 kHz，单声道，Float32，[-1.0, 1.0]
  Future<String> recognize(List<double> samples) async {
    assert(_initialized, 'SttService: 必须先调用 initialize()');
    final rec = _recognizer!;

    final stream = rec.createStream();
    stream.acceptWaveform(
      samples: Float32List.fromList(samples),
      sampleRate: 16000,
    );
    rec.decode(stream);
    final result = rec.getResult(stream);
    stream.free();

    return result.text.trim();
  }

  /// 提取 asset → 本地缓存（sherpa_onnx C++ 层需要文件系统路径）
  Future<String> _extractAsset(String assetPath) async {
    final cacheDir = await getApplicationCacheDirectory();
    // 保留 asset 相对路径结构，防止不同模型文件名冲突
    final localPath =
        '${cacheDir.path}/glotalk_stt/${assetPath.replaceFirst('assets/models/stt/', '')}';
    final localFile = File(localPath);

    if (!localFile.existsSync()) {
      await localFile.parent.create(recursive: true);
      final data = await rootBundle.load(assetPath);
      await localFile.writeAsBytes(data.buffer.asUint8List());
    }
    return localFile.path;
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _initialized = false;
  }
}
