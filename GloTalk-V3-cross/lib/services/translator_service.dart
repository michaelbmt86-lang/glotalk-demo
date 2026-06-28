// 参考来源：
//   https://pub.dev/packages/flutter_onnxruntime (v1.8.0)
//   https://pub.dev/packages/flutter_onnxruntime/example — createSessionFromAsset 官方示例
//   https://huggingface.co/docs/optimum-onnx/onnx/usage_guides/export_a_model
//   https://github.com/huggingface/transformers/issues/26523
//   https://pub.dev/packages/dart_sentencepiece_tokenizer (v1.3.2)

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

/// 翻译结果，携带 token ids 供调试面板
class TranslationResult {
  final String translatedText;
  final List<int> encoderTokenIds;
  final List<int> decoderTokenIds;
  const TranslationResult({
    required this.translatedText,
    required this.encoderTokenIds,
    required this.decoderTokenIds,
  });
}

class TranslatorService {
  OnnxRuntime? _ort;
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;

  SentencePieceTokenizer? _sourceTokenizer;
  SentencePieceTokenizer? _targetTokenizer;
  bool _initialized = false;

  static const String _kEncoderAsset =
      'assets/models/translate/opus-mt-zh-en/encoder_model_int8.onnx';
  static const String _kDecoderAsset =
      'assets/models/translate/opus-mt-zh-en/decoder_model_int8.onnx';
  static const String _kSourceSpmAsset =
      'assets/models/translate/opus-mt-zh-en/source.spm';
  static const String _kTargetSpmAsset =
      'assets/models/translate/opus-mt-zh-en/target.spm';

  static const int _kPadId = 65000;
  static const int _kEosId = 0;
  static const int _kMaxLen = 128;

  Future<void> initialize() async {
    if (_initialized) return;

    _ort = OnnxRuntime();

    _encoderSession = await _ort!.createSessionFromAsset(_kEncoderAsset);
    _decoderSession = await _ort!.createSessionFromAsset(_kDecoderAsset);

    final sourcePath = await _extractAssetToFile(_kSourceSpmAsset);
    final targetPath = await _extractAssetToFile(_kTargetSpmAsset);
    _sourceTokenizer = await SentencePieceTokenizer.fromModelFile(sourcePath);
    _targetTokenizer = await SentencePieceTokenizer.fromModelFile(targetPath);

    _initialized = true;
  }

  Future<TranslationResult> translate(String chineseText) async {
    assert(_initialized, 'TranslatorService: 必须先调用 initialize()');

    final encoding = _sourceTokenizer!.encode(chineseText);
    final inputIdsRaw = [...encoding.ids, _kEosId];
    final seqLen = inputIdsRaw.length;

    final encInputIds = await OrtValue.fromList(
        List<int>.from(inputIdsRaw), [1, seqLen]);
    final encAttnMask = await OrtValue.fromList(
        List<int>.filled(seqLen, 1), [1, seqLen]);

    final encoderOut = await _encoderSession!.run({
      'input_ids': encInputIds,
      'attention_mask': encAttnMask,
    });
    final encoderHiddenStates = encoderOut['last_hidden_state']!;

    await encInputIds.dispose();
    await encAttnMask.dispose();

    final attentionMaskData = List<int>.filled(seqLen, 1);
    final decoderInputIds = [_kPadId];
    final generatedIds = <int>[];

    for (int step = 0; step < _kMaxLen; step++) {
      final decInputIds = await OrtValue.fromList(
          List<int>.from(decoderInputIds), [1, decoderInputIds.length]);
      final decAttnMask = await OrtValue.fromList(
          List<int>.filled(decoderInputIds.length, 1),
          [1, decoderInputIds.length]);
      final encAttnMaskStep = await OrtValue.fromList(
          List<int>.from(attentionMaskData), [1, seqLen]);

      late Map<String, OrtValue> decoderOut;
      try {
        decoderOut = await _decoderSession!.run({
          'input_ids': decInputIds,
          'attention_mask': decAttnMask,
          'encoder_hidden_states': encoderHiddenStates,
          'encoder_attention_mask': encAttnMaskStep,
        });
      } finally {
        await decInputIds.dispose();
        await decAttnMask.dispose();
        await encAttnMaskStep.dispose();
      }

      final logitsRaw = await decoderOut['logits']!.asList();
      for (final v in decoderOut.values) {
        await v.dispose();
      }

      final lastStepLogits = (logitsRaw[0] as List).last as List;
      int nextId = 0;
      double maxVal = double.negativeInfinity;
      for (int i = 0; i < lastStepLogits.length; i++) {
        final val = (lastStepLogits[i] as num).toDouble();
        if (val > maxVal) {
          maxVal = val;
          nextId = i;
        }
      }

      if (nextId == _kEosId) break;
      generatedIds.add(nextId);
      decoderInputIds.add(nextId);
    }

    await encoderHiddenStates.dispose();

    final translatedText = _targetTokenizer!.decode(generatedIds).trim();

    return TranslationResult(
      translatedText: translatedText,
      encoderTokenIds: List<int>.from(inputIdsRaw),
      decoderTokenIds: List<int>.from(generatedIds),
    );
  }

  Future<String> _extractAssetToFile(String assetPath) async {
    final cacheDir = await getApplicationCacheDirectory();
    final fileName = assetPath.split('/').last;
    final localFile = File('${cacheDir.path}/glotalk_translate/$fileName');
    if (!localFile.existsSync()) {
      await localFile.parent.create(recursive: true);
      final data = await rootBundle.load(assetPath);
      await localFile.writeAsBytes(data.buffer.asUint8List());
    }
    return localFile.path;
  }

  void dispose() {
    _encoderSession?.close();
    _decoderSession?.close();
    _encoderSession = null;
    _decoderSession = null;
    _initialized = false;
  }
}
