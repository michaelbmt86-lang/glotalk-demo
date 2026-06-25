// lib/services/translator_service.dart
//
// 翻译引擎：Helsinki-NLP/opus-mt-zh-en（MarianMT）
// 模型格式：encoder_model_int8.onnx + decoder_model_merged_int8.onnx
// 运行时：flutter_onnxruntime ^1.8.0（masic.ai，MIT）
// 分词：自实现 SentencePiece BPE 读取（source.spm vocab.json）
//
// 架构参考：onnx_translation 包 API 文档
//   https://pub.dev/documentation/onnx_translation/latest/
// ONNX 运行参考：flutter_onnxruntime 官方 readme
//   https://pub.dev/packages/flutter_onnxruntime
//
// 数据流：
//   中文文字 → SentencePiece 分词 → token id 序列
//   → encoder ONNX → decoder ONNX（beam-greedy）→ 英文文字

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

class TranslatorService {
  // ─── 单例 ──────────────────────────────────────────────────
  static final TranslatorService _instance = TranslatorService._internal();
  factory TranslatorService() => _instance;
  TranslatorService._internal();

  // ─── 内部状态 ──────────────────────────────────────────────
  bool _initialized = false;
  late OnnxRuntime _ort;
  late OrtSession _encoderSession;
  late OrtSession _decoderSession;

  // vocab.json 中的 token→id 映射（MarianMT 格式）
  late Map<String, int> _vocab;
  // id→token 反向映射（用于解码输出）
  late Map<int, String> _idToToken;

  // MarianMT 特殊 token id（来自 Helsinki-NLP/opus-mt-zh-en tokenizer_config）
  static const int _padId = 58100;   // <pad>
  static const int _eosId = 0;       // </s>
  static const int _bosId = 58100;   // 解码起始用 pad
  static const int _unkId = 1;       // <unk>
  // 目标语言前缀（MarianMT 中英方向无需 language token，直接送分词结果）

  // 最大序列长度（MarianMT 标准 512）
  static const int _maxLength = 128;

  // ─── 初始化 ────────────────────────────────────────────────
  Future<void> initialize() async {
    if (_initialized) return;

    _ort = OnnxRuntime();

    // 从 assets 加载两个 ONNX 模型
    // flutter_onnxruntime 1.8.0 支持 createSessionFromAsset
    _encoderSession = await _ort.createSessionFromAsset(
      'assets/models/opus-mt-zh-en/encoder_model_int8.onnx',
    );
    _decoderSession = await _ort.createSessionFromAsset(
      'assets/models/opus-mt-zh-en/decoder_model_merged_int8.onnx',
    );

    // 加载词表
    await _loadVocab();

    _initialized = true;
  }

  Future<void> _loadVocab() async {
    final raw = await rootBundle.loadString(
      'assets/models/opus-mt-zh-en/vocab.json',
    );
    final Map<String, dynamic> parsed = jsonDecode(raw);
    _vocab = parsed.map((k, v) => MapEntry(k, v as int));
    _idToToken = _vocab.map((k, v) => MapEntry(v, k));
  }

  // ─── 公开接口：翻译 ────────────────────────────────────────
  /// 将中文文字翻译为英文，返回英文字符串。
  /// 若模型未初始化则抛出 StateError。
  Future<String> translateZhToEn(String text) async {
    if (!_initialized) {
      throw StateError('TranslatorService: 请先调用 initialize()');
    }
    if (text.trim().isEmpty) return '';

    // Step 1: 分词 → input_ids
    final inputIds = _tokenize(text);

    // Step 2: 构造 attention_mask（全 1）
    final attentionMask = List<int>.filled(inputIds.length, 1);

    // Step 3: encoder forward pass
    final encoderHidden = await _runEncoder(inputIds, attentionMask);

    // Step 4: greedy decoder loop
    final outputIds = await _greedyDecode(
      encoderHidden,
      attentionMask,
      inputIds.length,
    );

    // Step 5: 解码 token ids → 英文字符串
    return _decode(outputIds);
  }

  // ─── 分词（SentencePiece BPE，手工实现查表版）──────────────
  // MarianMT 使用 SentencePiece Unigram，中文字符逐字切割后拼 ▁ 前缀
  // 此处采用字符级贪心最长匹配（可覆盖绝大多数中文输入）
  List<int> _tokenize(String text) {
    final tokens = <int>[];

    // MarianMT 输入格式：token 序列 + </s>
    // 中文字符按 ▁字 形式查表，找不到则用 <unk>
    bool firstToken = true;
    for (final char in text.characters) {
      if (char.trim().isEmpty) {
        firstToken = true;
        continue;
      }
      // SentencePiece 首词无空格前缀，后续词有 ▁ 前缀
      final key = firstToken ? char : '▁$char';
      final altKey = firstToken ? '▁$char' : char;
      final id = _vocab[key] ?? _vocab[altKey] ?? _unkId;
      tokens.add(id);
      firstToken = false;
    }

    // 末尾加 </s>（EOS）
    tokens.add(_eosId);

    // 截断到最大长度
    if (tokens.length > _maxLength) {
      return [...tokens.sublist(0, _maxLength - 1), _eosId];
    }
    return tokens;
  }

  // ─── Encoder forward ──────────────────────────────────────
  Future<Map<String, OrtValue>> _runEncoder(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    final seqLen = inputIds.length;

    // flutter_onnxruntime: OrtValue.fromList(data, shape)
    final inputIdsTensor = await OrtValue.fromList(
      inputIds,
      [1, seqLen],
    );
    final attMaskTensor = await OrtValue.fromList(
      attentionMask,
      [1, seqLen],
    );

    final outputs = await _encoderSession.run({
      'input_ids': inputIdsTensor,
      'attention_mask': attMaskTensor,
    });

    // 释放输入 tensor
    await inputIdsTensor.dispose();
    await attMaskTensor.dispose();

    return outputs;
  }

  // ─── Greedy decode loop ───────────────────────────────────
  // MarianMT decoder_model_merged_int8.onnx 接口：
  //   输入: input_ids, encoder_hidden_states, encoder_attention_mask
  //         (+ past_key_values 在 merged 模型中可选)
  //   输出: logits [1, seq, vocab_size]
  //
  // 参考：HuggingFace optimum ONNX export 规格
  Future<List<int>> _greedyDecode(
    Map<String, OrtValue> encoderOutputs,
    List<int> srcAttentionMask,
    int srcLen,
  ) async {
    final decoderInputIds = [_bosId]; // 起始 token
    final generatedIds = <int>[];
    final maxGenLen = _maxLength;

    // 获取 encoder_last_hidden_state
    final encoderHidden = encoderOutputs['last_hidden_state'];
    if (encoderHidden == null) {
      throw StateError('Encoder 输出缺少 last_hidden_state');
    }

    final srcMaskTensor = await OrtValue.fromList(
      srcAttentionMask,
      [1, srcLen],
    );

    for (int step = 0; step < maxGenLen; step++) {
      final decInputTensor = await OrtValue.fromList(
        decoderInputIds,
        [1, decoderInputIds.length],
      );

      final decOutputs = await _decoderSession.run({
        'input_ids': decInputTensor,
        'encoder_hidden_states': encoderHidden,
        'encoder_attention_mask': srcMaskTensor,
      });

      await decInputTensor.dispose();

      // logits shape: [1, seq_len, vocab_size]
      final logits = decOutputs['logits'];
      if (logits == null) break;

      final logitData = await logits.asList() as List;
      await logits.dispose();

      // 取最后一个时间步的 logits，argmax
      // logitData 是 Float32List 展开的 flat list
      // 总元素 = 1 * seq_len * vocab_size
      final vocabSize = _vocab.length;
      final lastStepOffset = (decoderInputIds.length - 1) * vocabSize;

      int nextId = _padId;
      double maxVal = double.negativeInfinity;
      for (int i = 0; i < vocabSize; i++) {
        final val = (logitData[lastStepOffset + i] as num).toDouble();
        if (val > maxVal) {
          maxVal = val;
          nextId = i;
        }
      }

      if (nextId == _eosId) break;
      generatedIds.add(nextId);
      decoderInputIds.add(nextId);
    }

    // 清理
    await srcMaskTensor.dispose();
    for (final v in encoderOutputs.values) {
      await v.dispose();
    }

    return generatedIds;
  }

  // ─── Token ids → 文字 ─────────────────────────────────────
  String _decode(List<int> ids) {
    final pieces = ids.map((id) => _idToToken[id] ?? '').toList();
    // SentencePiece: ▁ 代表空格前缀，直接替换还原
    return pieces.join('').replaceAll('▁', ' ').trim();
  }

  // ─── 调试工具：打印 tokenizer 结果 ────────────────────────
  /// 返回给定文本的 token id 列表（供 verify_screen 调试按钮调用）
  Future<List<int>> debugTokenize(String text) async {
    if (!_initialized) await initialize();
    return _tokenize(text);
  }

  // ─── 释放资源 ──────────────────────────────────────────────
  Future<void> dispose() async {
    if (!_initialized) return;
    await _encoderSession.close();
    await _decoderSession.close();
    _initialized = false;
  }
}

// Dart 3.0+ String.characters 扩展需要此 extension
// （避免对 characters 包的额外依赖，直接按码元遍历）
extension on String {
  Iterable<String> get characters sync* {
    for (final rune in runes) {
      yield String.fromCharCode(rune);
    }
  }
}
