# GloTalk V3 验证分支 — 智能体工作手册

## 身份与原则

你是 GloTalk V3 验证分支的专属开发智能体。

**核心原则（永远不违反）：**
1. 动手前必读官方文档，查证后才能写代码
2. 搭积木不造轮子，每块积木都有官方出处
3. 给完整代码，不做局部补丁
4. 每次改动必须说明参考了哪个官方文档的哪个部分
5. 安全第一，宁可多做验证步骤，不走捷径
6. 遇到不确定的地方，先说"我不确定，需要查证"，不猜测

---

## 项目背景

**目标**：在新分支 `v3-opus-verify` 验证「一句中文进去、英文出来」的完整设备端管线。

**不涉及**：LiveKit、音频、STT、aliabba-v1，本次只验证翻译积木。

**测试设备**：Redmi K30i（骁龙765G，Android 12，6GB RAM）

---

## 技术栈（已查证，所有版本号来自官方 pub.dev）

### 四块积木

| 积木 | 包名 | 版本 | 平台 | 来源 |
|------|------|------|------|------|
| ONNX 推理 | `flutter_onnxruntime` | `^1.7.0` | Android ✅ iOS ✅ | pub.dev/packages/flutter_onnxruntime |
| Tokenizer | `dart_sentencepiece_tokenizer` | `^1.3.1` | 纯 Dart ✅ | pub.dev/packages/dart_sentencepiece_tokenizer |
| TTS | `flutter_tts` | `^4.2.5` | Android ✅ iOS ✅ | pub.dev/packages/flutter_tts |
| 权限 | `permission_handler` | `^12.0.1` | Android ✅ iOS ✅ | 现有 App 已有 |

### 模型文件（已查证真实大小）

来源：`onnx-community/opus-mt-zh-en`（HuggingFace，CC-BY 4.0）

| 文件 | 大小 | 用途 |
|------|------|------|
| `encoder_model_int8.onnx` | 52.9 MB | 编码中文输入 |
| `decoder_model_merged_int8.onnx` | 193 MB | 自回归解码生成英文 |
| `source.spm` | ~800 KB | 中文 tokenizer 模型 |
| `target.spm` | ~800 KB | 英文 detokenizer 模型 |
| `vocab.json` | ~2 MB | 词汇表（token→id 映射） |

**注意**：`dart_sentencepiece_tokenizer` 从 `.spm` 文件加载，不需要 `tokenizer.json`。

---

## 完整 pubspec.yaml

```yaml
name: glotalk_v3_verify
description: GloTalk V3 翻译验证分支 — Opus-MT ONNX on-device

publish_to: 'none'

version: 0.1.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter

  # ONNX Runtime — 官方文档: pub.dev/packages/flutter_onnxruntime
  # 版本 1.7.0，支持 ONNX Runtime 1.22.0，Android 需要 proguard-rules.pro
  flutter_onnxruntime: ^1.7.0

  # SentencePiece Tokenizer — 纯 Dart，无 FFI，无原生依赖
  # 官方文档: pub.dev/packages/dart_sentencepiece_tokenizer
  # 支持 Unigram 算法（Opus-MT 使用的算法）
  dart_sentencepiece_tokenizer: ^1.3.1

  # TTS — 调手机系统 TTS 引擎
  # 官方文档: pub.dev/packages/flutter_tts
  flutter_tts: ^4.2.5

  # 路径工具（flutter_onnxruntime 依赖）
  path_provider: ^2.1.5

  # 权限（麦克风，为后续 STT 准备）
  permission_handler: ^12.0.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true

  assets:
    # ONNX 模型文件 — 从 onnx-community/opus-mt-zh-en 下载
    - assets/models/opus-mt-zh-en/encoder_model_int8.onnx
    - assets/models/opus-mt-zh-en/decoder_model_merged_int8.onnx
    # Tokenizer 文件 — 从同一 HuggingFace repo 下载
    - assets/models/opus-mt-zh-en/source.spm
    - assets/models/opus-mt-zh-en/target.spm
    - assets/models/opus-mt-zh-en/vocab.json
```

---

## Android 必要配置

### android/app/proguard-rules.pro
```
# flutter_onnxruntime 官方要求（来自 pub.dev 文档）
-keep class ai.onnxruntime.** { *; }
```

### android/app/build.gradle.kts
```kotlin
android {
    compileSdk = 36
    defaultConfig {
        minSdk = 24  // flutter_tts pause 功能需要 SDK 26+，建议 24
        targetSdk = 36
    }
    buildTypes {
        release {
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}
```

### android/app/src/main/AndroidManifest.xml 新增
```xml
<!-- TTS 服务查询（Android 11+ 必须）-->
<queries>
  <intent>
    <action android:name="android.intent.action.TTS_SERVICE" />
  </intent>
</queries>
```

---

## OpusMTTranslator 完整代码骨架

文件路径：`lib/services/opus_mt_translator.dart`

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';

/// GloTalk V3 — Helsinki-NLP Opus-MT 中英翻译器
///
/// 参考来源：
/// - flutter_onnxruntime API: pub.dev/documentation/flutter_onnxruntime/latest/
/// - dart_sentencepiece_tokenizer API: pub.dev/documentation/dart_sentencepiece_tokenizer/latest/
/// - MarianMT tokenizer 规格: huggingface.co/docs/transformers/en/model_doc/marian
/// - ONNX 推理流程: github.com/masicai/flutter_onnxruntime/blob/main/doc/api_usage.md
///
/// Opus-MT 特殊 token（来自 HuggingFace MarianTokenizer 官方文档）：
/// - pad_token_id = 65000（<pad>），decoder 起始 token
/// - eos_token_id = 0（</s>），生成结束信号
/// - max_length = 512
class OpusMTTranslator {
  // ─── 私有字段 ───────────────────────────────────────────────────────────────

  OrtSession? _encoderSession;
  OrtSession? _decoderSession;
  SentencePieceTokenizer? _srcTokenizer; // 中文 source.spm
  SentencePieceTokenizer? _tgtTokenizer; // 英文 target.spm
  Map<String, int>? _vocab;              // vocab.json: token→id
  Map<int, String>? _vocabInverse;       // id→token（用于解码输出）

  bool _isLoaded = false;

  // ─── Opus-MT 特殊 token（来自 MarianTokenizer 官方文档）────────────────────
  static const int _padTokenId = 65000; // <pad>，decoder 的起始 token
  static const int _eosTokenId = 0;     // </s>，生成结束标志
  static const int _maxLength = 512;
  static const int _maxGenerateLength = 256; // 输出最大 token 数

  // ─── 公开方法 ───────────────────────────────────────────────────────────────

  /// 加载所有模型和 tokenizer
  /// 应在 App 启动时在后台调用一次，加载完成前不能调用 translate()
  Future<void> load() async {
    if (_isLoaded) return;

    try {
      // 1. 加载 encoder ONNX 模型
      //    flutter_onnxruntime API: OnnxRuntime().createSessionFromAsset()
      final ort = OnnxRuntime();
      _encoderSession = await ort.createSessionFromAsset(
        'assets/models/opus-mt-zh-en/encoder_model_int8.onnx',
      );

      // 2. 加载 decoder ONNX 模型（merged 版本包含 past_key_values 缓存）
      _decoderSession = await ort.createSessionFromAsset(
        'assets/models/opus-mt-zh-en/decoder_model_merged_int8.onnx',
      );

      // 3. 加载中文 source tokenizer（Unigram 算法）
      //    dart_sentencepiece_tokenizer API: SentencePieceTokenizer.fromModelFile()
      //    注意：MarianMT 用 source.spm 做输入 tokenize
      final srcBytes = await rootBundle.load(
        'assets/models/opus-mt-zh-en/source.spm',
      );
      _srcTokenizer = await SentencePieceTokenizer.fromModelBytes(
        srcBytes.buffer.asUint8List(),
      );

      // 4. 加载英文 target tokenizer（用于输出 detokenize）
      final tgtBytes = await rootBundle.load(
        'assets/models/opus-mt-zh-en/target.spm',
      );
      _tgtTokenizer = await SentencePieceTokenizer.fromModelBytes(
        tgtBytes.buffer.asUint8List(),
      );

      // 5. 加载词汇表（vocab.json → token→id 映射）
      //    MarianMT 的 vocab.json 是 {"token": id} 格式
      final vocabJson = await rootBundle.loadString(
        'assets/models/opus-mt-zh-en/vocab.json',
      );
      _vocab = Map<String, int>.from(json.decode(vocabJson) as Map);
      _vocabInverse = {for (final e in _vocab!.entries) e.value: e.key};

      _isLoaded = true;
    } catch (e) {
      // 加载失败时清理，允许重试
      await dispose();
      rethrow;
    }
  }

  /// 翻译中文文本为英文
  /// 必须先调用 load() 完成后才能使用
  Future<String> translate(String chineseText) async {
    if (!_isLoaded) throw StateError('OpusMTTranslator 未加载，请先调用 load()');
    if (chineseText.trim().isEmpty) return '';

    // ── Step 1: Tokenize 输入中文 ──────────────────────────────────────────
    //   dart_sentencepiece_tokenizer: tokenizer.encode(text)
    //   返回 Encoding 对象，.ids 是 List<int>
    final encoding = _srcTokenizer!.encode(
      chineseText.trim(),
    );

    // MarianMT 输入格式：token_ids + [eos_token_id]，截断到 maxLength-1 再加 EOS
    final List<int> rawIds = encoding.ids;
    final List<int> truncated = rawIds.length > (_maxLength - 1)
        ? rawIds.sublist(0, _maxLength - 1)
        : rawIds;
    final List<int> inputIds = [...truncated, _eosTokenId];
    final int seqLen = inputIds.length;

    // attention_mask: 全 1（无 padding，因为单句推理）
    final List<int> attentionMask = List.filled(seqLen, 1);

    // ── Step 2: Encoder 推理 ───────────────────────────────────────────────
    //   flutter_onnxruntime API:
    //   OrtValue.fromList(data, shape) → session.run(inputs) → outputs
    //
    //   encoder 输入名称（来自 ONNX 模型，标准 MarianMT）：
    //   - "input_ids"      shape: [1, seqLen]  dtype: int64
    //   - "attention_mask" shape: [1, seqLen]  dtype: int64
    //
    //   encoder 输出名称：
    //   - "last_hidden_state" shape: [1, seqLen, 512]

    final encoderInputIds = await OrtValue.fromList(
      inputIds.map((e) => e.toInt()).toList(),
      [1, seqLen],
    );
    final encoderAttentionMask = await OrtValue.fromList(
      attentionMask.map((e) => e.toInt()).toList(),
      [1, seqLen],
    );

    final encoderOutputs = await _encoderSession!.run({
      'input_ids': encoderInputIds,
      'attention_mask': encoderAttentionMask,
    });

    final encoderHiddenState = encoderOutputs['last_hidden_state']!;

    // 清理 encoder 输入 tensor
    await encoderInputIds.dispose();
    await encoderAttentionMask.dispose();

    // ── Step 3: Decoder 自回归循环（Greedy Decoding）───────────────────────
    //   decoder_merged 同时处理首次（无 past）和后续（有 past_key_values）步骤
    //
    //   decoder 每步输入：
    //   - "input_ids"                      shape: [1, 1]     当前 token
    //   - "encoder_hidden_states"          shape: [1, seqLen, 512]
    //   - "encoder_attention_mask"         shape: [1, seqLen]
    //   - "use_cache_branch"               shape: [1]  bool，首次 false，后续 true
    //   （后续步骤还需要传入上一步的 past_key_values，此处简化用无 past 版本）
    //
    //   ⚠️  简化说明：此骨架使用 decoder_model.onnx（非 merged）的无缓存推理方式，
    //   每步重新计算全部 attention，速度较慢但实现简单，适合验证阶段。
    //   生产版本应使用 past_key_values 缓存加速。

    final List<int> generatedIds = [];
    int currentTokenId = _padTokenId; // decoder 从 <pad> 开始

    // 重新创建 encoder attention mask 供 decoder 使用
    final decoderEncoderMask = await OrtValue.fromList(
      attentionMask.map((e) => e.toInt()).toList(),
      [1, seqLen],
    );

    for (int step = 0; step < _maxGenerateLength; step++) {
      // decoder 当前输入：[batchSize=1, seqLen=1]
      final List<int> decoderInputSeq = [
        ...generatedIds,
        currentTokenId,
      ];
      final int decSeqLen = decoderInputSeq.length;

      final decoderInputIds = await OrtValue.fromList(
        decoderInputSeq.map((e) => e.toInt()).toList(),
        [1, decSeqLen],
      );

      // ⚠️  注意：decoder_model_merged_int8.onnx 的输入名称需要在首次运行时
      //   通过 session.inputNames 打印确认，不同版本可能略有差异。
      //   标准 MarianMT ONNX 的 decoder 输入名：
      //   "input_ids", "encoder_hidden_states", "encoder_attention_mask"
      final decoderOutputs = await _decoderSession!.run({
        'input_ids': decoderInputIds,
        'encoder_hidden_states': encoderHiddenState,
        'encoder_attention_mask': decoderEncoderMask,
      });

      await decoderInputIds.dispose();

      // decoder 输出 "logits" shape: [1, decSeqLen, vocabSize]
      // 取最后一个位置的 logits，找 argmax
      final logitsTensor = decoderOutputs['logits']!;
      final logitsList = await logitsTensor.asList() as List;
      await logitsTensor.dispose();

      // logits 展平后：总元素 = 1 * decSeqLen * vocabSize
      // 取最后 vocabSize 个元素（最后一个时间步的 logits）
      final int vocabSize = _vocab!.length;
      final List lastStepLogits = logitsList.sublist(
        logitsList.length - vocabSize,
      );

      // Greedy：取概率最高的 token id
      int bestId = 0;
      double bestVal = (lastStepLogits[0] as num).toDouble();
      for (int i = 1; i < lastStepLogits.length; i++) {
        final double val = (lastStepLogits[i] as num).toDouble();
        if (val > bestVal) {
          bestVal = val;
          bestId = i;
        }
      }

      // 遇到 EOS 停止
      if (bestId == _eosTokenId) break;

      generatedIds.add(bestId);
      currentTokenId = bestId;

      // 释放其余 decoder 输出（past_key_values 等）
      for (final v in decoderOutputs.values) {
        try { await v.dispose(); } catch (_) {}
      }
    }

    // 清理 encoder 输出和 decoder mask
    await encoderHiddenState.dispose();
    await decoderEncoderMask.dispose();

    // ── Step 4: Detokenize 输出 token ids → 英文文本 ───────────────────────
    //   dart_sentencepiece_tokenizer: tokenizer.decode(ids)
    //   注意：用 target.spm（英文）做 decode，不是 source.spm
    final String result = _tgtTokenizer!.decode(generatedIds);

    return result.trim();
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await _encoderSession?.close();
    await _decoderSession?.close();
    _encoderSession = null;
    _decoderSession = null;
    _srcTokenizer = null;
    _tgtTokenizer = null;
    _vocab = null;
    _vocabInverse = null;
    _isLoaded = false;
  }

  bool get isLoaded => _isLoaded;
}
```

---

## 验证页面骨架

文件路径：`lib/screens/verify_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../services/opus_mt_translator.dart';

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});
  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _translator = OpusMTTranslator();
  final _tts = FlutterTts();
  final _inputController = TextEditingController();

  String _status = '未加载';
  String _result = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadModel();
    // flutter_tts 配置
    _tts.setLanguage('en-US');
    _tts.setSpeechRate(0.9);
  }

  Future<void> _loadModel() async {
    setState(() { _status = '加载模型中...（约需 5-15 秒）'; });
    final sw = Stopwatch()..start();
    try {
      await _translator.load();
      sw.stop();
      setState(() { _status = '模型已加载 ✅（${sw.elapsedMilliseconds}ms）'; });
    } catch (e) {
      setState(() { _status = '加载失败 ❌: $e'; });
    }
  }

  Future<void> _translate() async {
    if (!_translator.isLoaded) return;
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() { _loading = true; _result = '翻译中...'; });
    final sw = Stopwatch()..start();
    try {
      final result = await _translator.translate(text);
      sw.stop();
      setState(() {
        _result = result;
        _loading = false;
        _status = '✅ 翻译完成（${sw.elapsedMilliseconds}ms）';
      });
    } catch (e) {
      setState(() { _result = '错误: $e'; _loading = false; });
    }
  }

  Future<void> _speak() async {
    if (_result.isEmpty || _result.startsWith('错误')) return;
    await _tts.speak(_result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GloTalk V3 验证')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 状态栏
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.grey[200],
              child: Text(_status, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 16),
            // 输入框
            TextField(
              controller: _inputController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '输入中文',
                border: OutlineInputBorder(),
                hintText: '例如：你好，我叫小明。',
              ),
            ),
            const SizedBox(height: 12),
            // 翻译按钮
            ElevatedButton(
              onPressed: _loading ? null : _translate,
              child: Text(_loading ? '翻译中...' : '翻译为英文'),
            ),
            const SizedBox(height: 16),
            // 结果显示
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _result.isEmpty ? '翻译结果将显示在这里' : _result,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 12),
            // 朗读按钮
            OutlinedButton(
              onPressed: _result.isEmpty ? null : _speak,
              child: const Text('朗读英文'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _translator.dispose();
    _tts.stop();
    _inputController.dispose();
    super.dispose();
  }
}
```

---

## 验证步骤（按顺序执行）

### 步骤 0：在 Python 环境生成参考输出（必须先做）

在把代码推到手机之前，必须用 Python 生成正确的参考 token ids，用于验证 Dart tokenizer 是否输出一致。

```python
# 运行环境：本地 Python，pip install transformers sentencepiece
from transformers import MarianTokenizer

tokenizer = MarianTokenizer.from_pretrained("Helsinki-NLP/opus-mt-zh-en")
text = "你好，我叫小明。"
encoded = tokenizer([text], return_tensors="pt", padding=True)
print("input_ids:", encoded["input_ids"][0].tolist())
# 期望输出类似：[4827, 8, 105, 3, 45, 6, 0]
# 记录这个数字序列，与 Dart 端输出对比
```

### 步骤 1：下载模型文件

```bash
# 安装 huggingface_hub
pip install huggingface_hub

# 下载 int8 量化 ONNX 文件
python -c "
from huggingface_hub import hf_hub_download
import os

repo = 'onnx-community/opus-mt-zh-en'
files = [
    'onnx/encoder_model_int8.onnx',
    'onnx/decoder_model_merged_int8.onnx',
]
for f in files:
    path = hf_hub_download(repo_id=repo, filename=f)
    print(f'Downloaded: {path}')
"

# 下载 tokenizer 文件（从原始 Helsinki-NLP repo）
python -c "
from huggingface_hub import hf_hub_download
repo = 'Helsinki-NLP/opus-mt-zh-en'
for f in ['source.spm', 'target.spm', 'vocab.json']:
    path = hf_hub_download(repo_id=repo, filename=f)
    print(f'Downloaded: {path}')
"
```

把下载的文件放到：
```
flutter_app/v3_verify/assets/models/opus-mt-zh-en/
├── encoder_model_int8.onnx      # 52.9 MB
├── decoder_model_merged_int8.onnx  # 193 MB
├── source.spm                   # ~800 KB
├── target.spm                   # ~800 KB
└── vocab.json                   # ~2 MB
```

### 步骤 2：验证 Tokenizer 一致性

在写完 Dart 代码后，加一个 debug 按钮，打印 `_srcTokenizer!.encode("你好，我叫小明。").ids`，对比步骤 0 的 Python 输出。如果不一致，翻译结果一定是乱码。

### 步骤 3：验证 Encoder 输出形状

在第一次 encoder 推理后，打印 `encoderHiddenState` 的 shape，应该是 `[1, seqLen, 512]`。如果形状不对，说明模型输入名称有误。

### 步骤 4：打印 decoder inputNames

```dart
// 加载后立即打印，确认输入名称与代码中一致
print('encoder inputs: ${_encoderSession!.inputNames}');
print('decoder inputs: ${_decoderSession!.inputNames}');
print('decoder outputs: ${_decoderSession!.outputNames}');
```

### 步骤 5：端到端测试句子

测试完成后，用这五句话验证翻译质量：
1. `你好，我叫小明。`  →  期望包含 "hello" 或 "my name is"
2. `今天天气很好。`  →  期望包含 "weather" 或 "today"
3. `我需要帮助。`  →  期望包含 "help"
4. `谢谢你。`  →  期望 "Thank you"
5. `我们在哪里？`  →  期望包含 "where"

---

## 已知问题和解决方案

### 问题 1：SentencePieceTokenizer.fromModelBytes 方法名
`dart_sentencepiece_tokenizer` 的 API 加载方式需确认。备用方案：
```dart
// 如果 fromModelBytes 不可用，用文件路径方式
final dir = await getApplicationDocumentsDirectory();
final spmPath = '${dir.path}/source.spm';
// 先把 asset 复制到临时目录再加载
```

### 问题 2：decoder_model_merged 输入名称不确定
merged 版本的 past_key_values 输入名称在不同导出版本间有差异。
**解决方案**：首次加载后立即打印 `session.inputNames`，根据实际名称调整代码。

### 问题 3：vocab.json 格式
MarianMT 的 vocab.json 是 `{"<pad>": 65000, "</s>": 0, ...}` 格式，
与普通 HuggingFace tokenizer.json 不同，直接 json.decode 即可。

### 问题 4：中文字符前缀
某些版本的 opus-mt-zh-en 需要在输入前加 `>>zh<<` 语言前缀，
如果翻译结果明显不对，尝试：
```dart
final textWithPrefix = '>>zh<< ${chineseText.trim()}';
```

---

## 完成标准

验证分支达到以下标准才算跑通：

- [ ] `flutter pub get` 无报错
- [ ] Codemagic 编译 APK 成功
- [ ] 安装到 Redmi K30i，App 启动不崩溃
- [ ] 模型加载成功（状态栏显示加载时间）
- [ ] 输入"你好"，输出合理英文
- [ ] 点击朗读，手机能发出英文 TTS 声音
- [ ] 翻译延迟记录（目标 <3 秒）

---

## 不在本次范围内

- LiveKit 接入
- STT（whisper）
- 双向翻译（en→zh）
- alibaba-v1 的任何代码
- 男女声切换
- 多语言对

这些全部留到验证分支通过后再开始。
