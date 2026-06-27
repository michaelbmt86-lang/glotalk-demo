// 参考来源：
//   https://pub.dev/packages/flutter_onnxruntime (v1.8.0)
//   https://pub.dev/packages/flutter_onnxruntime/example — createSessionFromAsset 官方示例
//   https://huggingface.co/docs/optimum-onnx/onnx/usage_guides/export_a_model
//     — decoder_model_merged.onnx 用 use_cache_branch 切换分支；第一次 pass bool=false
//   https://github.com/huggingface/transformers/issues/26523
//     — opus-mt encoder/decoder 分离使用示例（input_ids, attention_mask → encoder;
//       decoder: input_ids, attention_mask, encoder_hidden_states, encoder_attention_mask）
//   https://pub.dev/packages/dart_sentencepiece_tokenizer (v1.3.2)
//     — SentencePieceTokenizer.fromModelFile(path).encode(text).ids / .decode(ids)
//
// 修正 #3a：改用分离的 decoder_model_int8.onnx（非 merged），避免 use_cache_branch 复杂性
//   理由：decoder_model_merged 需要 dummy past_key_values（形状因模型层数而异），
//         在 flutter_onnxruntime 动态 tensor 环境下极易出错。
//         decoder_model_int8.onnx（无 past）是最安全、最简单的 greedy decode 方案。
//         输入：input_ids, attention_mask, encoder_hidden_states, encoder_attention_mask
//         来源：https://github.com/huggingface/transformers/issues/26523
//
// 修正 #3b：彻底修复 tensor dispose bug
//   原 bug：attentionMaskList 在 encoder 推理后被 dispose，decoder 循环里复用已释放的 tensor
//   修复：encoder_attention_mask 在每次 decoder 步骤里重新从 List<int> 创建 OrtValue，用完即 dispose

import 'dart:typed_data';
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

  // dart_sentencepiece_tokenizer v1.3.2
  // 来源：https://pub.dev/packages/dart_sentencepiece_tokenizer
  // API：SentencePieceTokenizer.fromModelFile(String path)
  //       .encode(String text) → Encoding（.ids → List<int>）
  //       .decode(List<int> ids) → String
  SentencePieceTokenizer? _sourceTokenizer;
  SentencePieceTokenizer? _targetTokenizer;
  bool _initialized = false;

  // Asset 路径（与 pubspec.yaml 声明一致）
  // 修正 #3a：使用分离的 decoder_model_int8.onnx（非 merged）
  static const String _kEncoderAsset =
      'assets/models/translate/opus-mt-zh-en/encoder_model_int8.onnx';
  static const String _kDecoderAsset =
      'assets/models/translate/opus-mt-zh-en/decoder_model_int8.onnx';
  static const String _kSourceSpmAsset =
      'assets/models/translate/opus-mt-zh-en/source.spm';
  static const String _kTargetSpmAsset =
      'assets/models/translate/opus-mt-zh-en/target.spm';

  // Marian / Opus-MT 特殊 token（来源：Helsinki-NLP/opus-mt-zh-en model card）
  // pad_token_id = 65000（decoder_start_token_id）
  // eos_token_id = 0
  static const int _kPadId = 65000;   // Marian decoder_start_token_id = pad
  static const int _kEosId = 0;
  static const int _kMaxLen = 128;

  Future<void> initialize() async {
    if (_initialized) return;

    _ort = OnnxRuntime();

    // ✅ 规范：必须用 createSessionFromAsset，不能用 createSession / createSessionFromFile
    // 来源：https://pub.dev/packages/flutter_onnxruntime/example
    _encoderSession = await _ort!.createSessionFromAsset(_kEncoderAsset);
    _decoderSession = await _ort!.createSessionFromAsset(_kDecoderAsset);

    // SentencePiece tokenizer 需要本地文件路径
    // 来源：https://pub.dev/packages/dart_sentencepiece_tokenizer
    //   SentencePieceTokenizer.fromModelFile(String filePath)
    final sourcePath = await _extractAssetToFile(_kSourceSpmAsset);
    final targetPath = await _extractAssetToFile(_kTargetSpmAsset);
    _sourceTokenizer = await SentencePieceTokenizer.fromModelFile(sourcePath);
    _targetTokenizer = await SentencePieceTokenizer.fromModelFile(targetPath);

    _initialized = true;
  }

  Future<TranslationResult> translate(String chineseText) async {
    assert(_initialized, 'TranslatorService: 必须先调用 initialize()');

    // ── Step 1: SentencePiece encode ─────────────────────────────────
    // 来源：https://pub.dev/packages/dart_sentencepiece_tokenizer
    //   encode(text) → Encoding，.ids 是 List<int>
    final encoding = _sourceTokenizer!.encode(chineseText);
    final inputIdsRaw = [...encoding.ids, _kEosId]; // 添加 EOS
    final seqLen = inputIdsRaw.length;

    // ── Step 2: Encoder 推理 ─────────────────────────────────────────
    // 输入：input_ids [1, seqLen] int64，attention_mask [1, seqLen] int64
    // 来源：https://github.com/huggingface/transformers/issues/26523
    final encInputIds = await OrtValue.fromList(
        List<int>.from(inputIdsRaw), [1, seqLen]);
    final encAttnMask = await OrtValue.fromList(
        List<int>.filled(seqLen, 1), [1, seqLen]);

    final encoderOut = await _encoderSession!.run({
      'input_ids': encInputIds,
      'attention_mask': encAttnMask,
    });
    final encoderHiddenStates = encoderOut['last_hidden_state']!;

    // ✅ 修正 #3b：encoder 输入用完立即 dispose，不再复用
    await encInputIds.dispose();
    await encAttnMask.dispose();

    // attentionMaskData 保存为 List<int>，每步 decoder 时重新创建 OrtValue
    final attentionMaskData = List<int>.filled(seqLen, 1);

    // ── Step 3: Decoder 自回归（greedy）────────────────────────────
    // decoder_model_int8.onnx 输入（无 past_key_values）：
    //   input_ids            [1, step]  int64
    //   attention_mask       [1, step]  int64  （decoder 侧注意力）
    //   encoder_hidden_states [1, seqLen, 512]  float32
    //   encoder_attention_mask [1, seqLen]  int64
    // 输出：logits [1, step, vocab_size]
    // 来源：https://github.com/huggingface/transformers/issues/26523
    final decoderInputIds = [_kPadId]; // Marian 以 pad_token_id 开始
    final generatedIds = <int>[];

    for (int step = 0; step < _kMaxLen; step++) {
      // ✅ 修正 #3b：每步都重新创建 tensor，用完立即 dispose，绝不复用已 dispose 的对象
      final decInputIds = await OrtValue.fromList(
          List<int>.from(decoderInputIds), [1, decoderInputIds.length]);
      final decAttnMask = await OrtValue.fromList(
          List<int>.filled(decoderInputIds.length, 1), [1, decoderInputIds.length]);
      // encoder_attention_mask：每步重新从 List<int> 创建（不复用已 dispose 的 tensor）
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
        // ✅ 修正 #3b：推理完成后立即 dispose 本步的输入 tensor
        await decInputIds.dispose();
        await decAttnMask.dispose();
        await encAttnMaskStep.dispose();
      }

      // logits: [1, step, vocab_size]，取最后一个时间步的 argmax
      final logitsRaw = await decoderOut['logits']!.asList() as List;
      // dispose decoder 输出（注意：encoderHiddenStates 在循环结束后统一 dispose）
      for (final v in decoderOut.values) {
        await v.dispose();
      }

      // 取 batch=0，最后一个时间步
      final lastStepLogits = (logitsRaw[0] as List).last as List;
      int nextId = 0;
      double maxVal = double.negativeInfinity;
      for (int i = 0; i < lastStepLogits.length; i++) {
        final val = (lastStepLogits[i] as num).toDouble();
        if (val > maxVal) { maxVal = val; nextId = i; }
      }

      if (nextId == _kEosId) break;
      generatedIds.add(nextId);
      decoderInputIds.add(nextId);
    }

    // ✅ 修正 #3b：循环结束后统一 dispose encoder hidden states
    await encoderHiddenStates.dispose();

    // ── Step 4: SentencePiece decode ─────────────────────────────────
    // 来源：https://pub.dev/packages/dart_sentencepiece_tokenizer
    //   decode(List<int> ids) → String
    final translatedText = _targetTokenizer!.decode(generatedIds).trim();

    return TranslationResult(
      translatedText: translatedText,
      encoderTokenIds: List<int>.from(inputIdsRaw),
      decoderTokenIds: List<int>.from(generatedIds),
    );
  }

  /// 将 asset 提取到本地缓存文件（SentencePiece tokenizer 需要文件路径）
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
