// GloTalk V3 — 翻译管线验证页 verify_screen.dart
//
// 验证目标：离线 STT → 离线翻译 → 离线 TTS，全程无网络、无 LiveKit
//
// 参考方案：
//   STT/TTS：k2-fsa/sherpa-onnx 官方 Flutter 示例
//            flutter-examples/streaming_asr/lib/streaming_asr.dart
//            flutter-examples/tts/ — OfflineTtsVitsModelConfig
//   翻译推理：flutter_onnxruntime pub.dev 官方 API
//            OnnxRuntime() → createSessionFromFile() → session.run()
//   设备端架构：Apple iOS 26 Live Translation 验证的"发送方本地处理"模式（V16 决策）
//
// 三个模型目录（由 main.dart 检查是否存在，本页面负责加载）：
//   <appDir>/models/stt/   → sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8
//   <appDir>/models/mt/    → opus-mt-zh-en ONNX encoder + decoder + tokenizer
//   <appDir>/models/tts/   → vits-piper-en_US-libritts_r-medium

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

// ──────────────────────────────────────────────
// 模型路径常量
// ──────────────────────────────────────────────
const _kSttDir = 'models/stt/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8';
const _kSttModel = 'model.int8.onnx';
const _kSttTokens = 'tokens.txt';

const _kMtDir = 'models/mt/opus-mt-zh-en';
const _kMtEncoder = 'encoder_model_int8.onnx';
const _kMtDecoder = 'decoder_model_merged_int8.onnx';

const _kTtsDir = 'models/tts/vits-piper-en_US-libritts_r-medium';
const _kTtsModel = 'en_US-libritts_r-medium.onnx';
const _kTtsDataDir = 'espeak-ng-data'; // 相对于 _kTtsDir

// ──────────────────────────────────────────────
// 管线状态枚举
// ──────────────────────────────────────────────
enum _PipelineState {
  idle,        // 等待录音
  recording,   // 录音中
  transcribing, // STT 处理
  translating, // 翻译中
  synthesizing, // TTS 合成
  playing,     // 播放中
  error,
}

// ──────────────────────────────────────────────
// 验证结果数据类
// ──────────────────────────────────────────────
class _VerifyResult {
  final String sourceText;   // STT 输出（中文）
  final String translatedText; // MT 输出（英文）
  final int ttsMs;           // TTS 耗时 ms
  final int totalMs;         // 全管线耗时 ms

  const _VerifyResult({
    required this.sourceText,
    required this.translatedText,
    required this.ttsMs,
    required this.totalMs,
  });
}

// ──────────────────────────────────────────────
// VerifyScreen
// ──────────────────────────────────────────────
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  // ── 状态 ──────────────────────────────────
  _PipelineState _pipelineState = _PipelineState.idle;
  String _statusMsg = '模型加载中…';
  String _errorMsg = '';
  final List<_VerifyResult> _results = [];

  // ── 模型加载状态 ──────────────────────────
  bool _modelsReady = false;
  final Map<String, bool> _modelReady = {
    'STT': false,
    'MT': false,
    'TTS': false,
  };

  // ── sherpa-onnx 对象（官方 Dart API）──────
  // 使用 OfflineRecognizer（SenseVoice），不需要流式推送
  // 因为验证场景是"按下录音→松开→识别"，与 Telegram 语音消息模式一致
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.OfflineTts? _tts;

  // ── flutter_onnxruntime 翻译 session ──────
  OnnxRuntime? _ort;
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;

  // ── 录音器 ────────────────────────────────
  final AudioRecorder _recorder = AudioRecorder();
  List<int> _recordedBytes = [];
  StreamSubscription<Uint8List>? _recordSub;

  // ── 简易 tokenizer（占位，待接 sentencepiece）──
  // V3 验证阶段先用文字输入绕过 tokenizer，
  // 确认 ONNX encoder/decoder pipeline 通后再接 sentencepiece
  final TextEditingController _textInputCtrl = TextEditingController(
    text: '你好，很高兴认识你',
  );
  bool _useTextInput = true; // 验证分支默认启用文字输入模式，绕过麦克风

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _recordSub?.cancel();
    _recorder.dispose();
    _recognizer?.free();
    _tts?.free();
    _encoderSession?.close();
    _decoderSession?.close();
    _textInputCtrl.dispose();
    super.dispose();
  }

  // ──────────────────────────────────────────
  // 模型加载
  // ──────────────────────────────────────────
  Future<void> _loadModels() async {
    final appDir = await getApplicationDocumentsDirectory();
    final base = appDir.path;

    // 并行加载三个模型，独立报告状态
    await Future.wait([
      _loadStt(base),
      _loadMt(base),
      _loadTts(base),
    ]);

    final allReady = _modelReady.values.every((v) => v);
    setState(() {
      _modelsReady = allReady;
      _statusMsg = allReady
          ? '所有模型已就绪 ✅\n选择输入方式后点击开始'
          : '部分模型缺失，请检查目录（详见下方）';
      if (_pipelineState != _PipelineState.error) {
        _pipelineState = _PipelineState.idle;
      }
    });
  }

  /// STT — sherpa-onnx SenseVoice int8
  /// 参考：sherpa-onnx 官方 flutter-examples/streaming_asr
  Future<void> _loadStt(String base) async {
    try {
      final sttDir = '$base/$_kSttDir';
      if (!await Directory(sttDir).exists()) {
        _updateModelState('STT', false, '目录不存在: $sttDir');
        return;
      }

      sherpa.initBindings();

      final senseVoice = sherpa.OfflineSenseVoiceModelConfig(
        model: '$sttDir/$_kSttModel',
        language: 'auto',      // 自动检测（SenseVoice 支持中英日韩粤）
        useInverseTextNormalization: true,
      );

      final modelConfig = sherpa.OfflineModelConfig(
        senseVoice: senseVoice,
        tokens: '$sttDir/$_kSttTokens',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );

      final config = sherpa.OfflineRecognizerConfig(
        model: modelConfig,
      );

      _recognizer = sherpa.OfflineRecognizer(config);
      _updateModelState('STT', true, 'SenseVoice int8 ✅');
    } catch (e) {
      _updateModelState('STT', false, '加载失败: $e');
    }
  }

  /// MT — flutter_onnxruntime + Opus-MT ONNX
  /// 参考：flutter_onnxruntime pub.dev 官方 API
  ///        OnnxRuntime() → createSessionFromFile() → session.run()
  Future<void> _loadMt(String base) async {
    try {
      final mtDir = '$base/$_kMtDir';
      final encoderPath = '$mtDir/$_kMtEncoder';
      final decoderPath = '$mtDir/$_kMtDecoder';

      if (!await File(encoderPath).exists() ||
          !await File(decoderPath).exists()) {
        _updateModelState('MT', false, '模型文件缺失: $mtDir');
        return;
      }

      _ort = OnnxRuntime();

      // encoder
      _encoderSession = await _ort!.createSessionFromFile(
        encoderPath,
        options: OrtSessionOptions()..setInterOpNumThreads(2),
      );

      // decoder（merged，含 past_key_values 缓存）
      _decoderSession = await _ort!.createSessionFromFile(
        decoderPath,
        options: OrtSessionOptions()..setInterOpNumThreads(2),
      );

      _updateModelState('MT', true, 'Opus-MT int8 ✅');
    } catch (e) {
      _updateModelState('MT', false, '加载失败: $e');
    }
  }

  /// TTS — sherpa-onnx VITS Piper English
  /// 参考：sherpa-onnx 官方 flutter-examples/tts
  ///        OfflineTtsVitsModelConfig → OfflineTts → tts.generate()
  Future<void> _loadTts(String base) async {
    try {
      final ttsDir = '$base/$_kTtsDir';
      if (!await Directory(ttsDir).exists()) {
        _updateModelState('TTS', false, '目录不存在: $ttsDir');
        return;
      }

      final vits = sherpa.OfflineTtsVitsModelConfig(
        model: '$ttsDir/$_kTtsModel',
        lexicon: '',             // Piper 模型不需要 lexicon.txt
        tokens: '$ttsDir/tokens.txt',
        dataDir: '$ttsDir/$_kTtsDataDir', // espeak-ng 数据目录
      );

      final modelConfig = sherpa.OfflineTtsModelConfig(
        vits: vits,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );

      final config = sherpa.OfflineTtsConfig(
        model: modelConfig,
        maxNumSentences: 1,
      );

      _tts = sherpa.OfflineTts(config);
      _updateModelState('TTS', true, 'VITS Piper EN ✅');
    } catch (e) {
      _updateModelState('TTS', false, '加载失败: $e');
    }
  }

  void _updateModelState(String key, bool ok, String msg) {
    if (mounted) {
      setState(() {
        _modelReady[key] = ok;
        if (!ok && _pipelineState != _PipelineState.error) {
          _pipelineState = _PipelineState.error;
          _errorMsg = msg;
        }
      });
    }
  }

  // ──────────────────────────────────────────
  // 管线执行：文字输入模式（验证 MT + TTS）
  // ──────────────────────────────────────────
  Future<void> _runTextPipeline() async {
    if (!_modelsReady) return;
    final inputText = _textInputCtrl.text.trim();
    if (inputText.isEmpty) return;

    final sw = Stopwatch()..start();

    setState(() {
      _pipelineState = _PipelineState.translating;
      _statusMsg = '翻译中…';
    });

    String translated = '';
    try {
      translated = await _translate(inputText);
    } catch (e) {
      setState(() {
        _pipelineState = _PipelineState.error;
        _errorMsg = '翻译失败: $e';
      });
      return;
    }

    setState(() {
      _pipelineState = _PipelineState.synthesizing;
      _statusMsg = 'TTS 合成中…';
    });

    final ttsStart = sw.elapsedMilliseconds;
    sherpa.OfflineTtsGeneratedAudio? audio;
    try {
      // tts.generate() 在 compute isolate 中运行，避免 UI 卡顿
      // 参考：sherpa-onnx flutter tts 官方示例的 compute() 用法
      audio = await compute(_generateTts, _TtsParams(
        tts: _tts!,
        text: translated,
        sid: 0,    // LibriTTS 随机说话人 0
        speed: 1.0,
      ));
    } catch (e) {
      setState(() {
        _pipelineState = _PipelineState.error;
        _errorMsg = 'TTS 失败: $e';
      });
      return;
    }

    final ttsMs = sw.elapsedMilliseconds - ttsStart;
    final totalMs = sw.elapsed.inMilliseconds;
    sw.stop();

    // 简单播放（验证阶段：直接用 AudioRecorder 的内置播放或写 WAV 文件）
    setState(() {
      _pipelineState = _PipelineState.playing;
      _statusMsg = '播放翻译音频…';
    });

    try {
      await _playPcm(audio.samples, audio.sampleRate);
    } catch (e) {
      // 播放失败不阻断结果显示
      debugPrint('[TTS play] $e');
    }

    setState(() {
      _results.insert(0, _VerifyResult(
        sourceText: inputText,
        translatedText: translated,
        ttsMs: ttsMs,
        totalMs: totalMs,
      ));
      _pipelineState = _PipelineState.idle;
      _statusMsg = '完成 ✅';
    });
  }

  // ──────────────────────────────────────────
  // 管线执行：语音录音模式（验证 STT + MT + TTS）
  // ──────────────────────────────────────────
  Future<void> _startRecording() async {
    final micOk = await Permission.microphone.request();
    if (!micOk.isGranted) {
      setState(() {
        _errorMsg = '需要麦克风权限';
        _pipelineState = _PipelineState.error;
      });
      return;
    }

    _recordedBytes = [];
    setState(() {
      _pipelineState = _PipelineState.recording;
      _statusMsg = '录音中… 松开按钮停止';
    });

    // PCM 16kHz mono，与 SenseVoice 要求一致
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ));

    _recordSub = stream.listen((data) {
      _recordedBytes.addAll(data);
    });
  }

  Future<void> _stopRecordingAndRun() async {
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();

    if (_recordedBytes.isEmpty) {
      setState(() {
        _pipelineState = _PipelineState.idle;
        _statusMsg = '没有录到音频，请重试';
      });
      return;
    }

    setState(() {
      _pipelineState = _PipelineState.transcribing;
      _statusMsg = 'STT 识别中…';
    });

    final sw = Stopwatch()..start();

    // 转换 bytes → Float32（16-bit LE PCM → [-1, 1]）
    final samples = _bytesToFloat32(Uint8List.fromList(_recordedBytes));

    // 官方 OfflineRecognizer 调用规格：
    // createStream → acceptWaveform → decode → getResult
    String sttText = '';
    try {
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _recognizer!.decode(stream);
      sttText = _recognizer!.getResult(stream).text;
      stream.free();
    } catch (e) {
      setState(() {
        _pipelineState = _PipelineState.error;
        _errorMsg = 'STT 失败: $e';
      });
      return;
    }

    if (sttText.trim().isEmpty) {
      setState(() {
        _pipelineState = _PipelineState.idle;
        _statusMsg = '未识别到语音，请重试';
      });
      return;
    }

    // 识别结果 → 翻译
    setState(() {
      _pipelineState = _PipelineState.translating;
      _statusMsg = '翻译中…\n识别: $sttText';
    });

    String translated = '';
    try {
      translated = await _translate(sttText);
    } catch (e) {
      setState(() {
        _pipelineState = _PipelineState.error;
        _errorMsg = '翻译失败: $e';
      });
      return;
    }

    setState(() {
      _pipelineState = _PipelineState.synthesizing;
      _statusMsg = 'TTS 合成中…';
    });

    final ttsStart = sw.elapsedMilliseconds;
    sherpa.OfflineTtsGeneratedAudio? audio;
    try {
      audio = await compute(_generateTts, _TtsParams(
        tts: _tts!,
        text: translated,
        sid: 0,
        speed: 1.0,
      ));
    } catch (e) {
      setState(() {
        _pipelineState = _PipelineState.error;
        _errorMsg = 'TTS 失败: $e';
      });
      return;
    }

    final ttsMs = sw.elapsedMilliseconds - ttsStart;
    final totalMs = sw.elapsed.inMilliseconds;
    sw.stop();

    setState(() {
      _pipelineState = _PipelineState.playing;
      _statusMsg = '播放翻译音频…';
    });

    try {
      await _playPcm(audio.samples, audio.sampleRate);
    } catch (e) {
      debugPrint('[TTS play] $e');
    }

    setState(() {
      _results.insert(0, _VerifyResult(
        sourceText: sttText,
        translatedText: translated,
        ttsMs: ttsMs,
        totalMs: totalMs,
      ));
      _pipelineState = _PipelineState.idle;
      _statusMsg = '完成 ✅';
    });
  }

  // ──────────────────────────────────────────
  // 翻译：flutter_onnxruntime + Opus-MT
  // 参考：pub.dev flutter_onnxruntime 官方 API
  //       OrtValue.fromList() → session.run() → asList()
  //
  // 注意：V3 验证阶段用占位 tokenizer（单字符 BPE 映射），
  //       sentencepiece 接入后直接替换 _tokenize / _detokenize
  // ──────────────────────────────────────────
  Future<String> _translate(String zhText) async {
    if (_encoderSession == null || _decoderSession == null) {
      throw Exception('翻译模型未加载');
    }

    // Step 1: tokenize（占位实现，实际需要 dart_sentencepiece_tokenizer）
    final inputIds = _placeholderTokenize(zhText);
    if (inputIds.isEmpty) return '[tokenizer error]';

    final seqLen = inputIds.length;

    // Step 2: encoder
    // Opus-MT encoder 输入：input_ids [1, seqLen], attention_mask [1, seqLen]
    final inputIdsOrt = await OrtValue.fromList(
      inputIds.map((e) => e.toDouble()).toList(),
      [1, seqLen],
    );
    final attentionMask = await OrtValue.fromList(
      List<double>.filled(seqLen, 1.0),
      [1, seqLen],
    );

    final encoderOutputs = await _encoderSession!.run({
      'input_ids': inputIdsOrt,
      'attention_mask': attentionMask,
    });

    inputIdsOrt.dispose();

    final encoderHiddenStates = encoderOutputs['last_hidden_state'];
    if (encoderHiddenStates == null) {
      for (final v in encoderOutputs.values) v?.dispose();
      attentionMask.dispose();
      throw Exception('encoder 输出为空');
    }

    // Step 3: decoder 自回归生成（最多 128 个 token）
    // 参考 Opus-MT HuggingFace decoder_model_merged 接口规格：
    //   输入：decoder_input_ids, encoder_hidden_states, encoder_attention_mask
    //   输出：logits（以及 present_key_values 缓存，merged 模型自动管理）
    final outputTokens = <int>[0]; // BOS token = 0（Opus-MT marian）
    const maxLen = 128;
    const eosTokenId = 0; // Opus-MT EOS = 0

    for (int step = 0; step < maxLen; step++) {
      final decInputOrt = await OrtValue.fromList(
        [outputTokens.last.toDouble()],
        [1, 1],
      );

      final decOutputs = await _decoderSession!.run({
        'decoder_input_ids': decInputOrt,
        'encoder_hidden_states': encoderHiddenStates,
        'encoder_attention_mask': attentionMask,
      });

      decInputOrt.dispose();

      final logits = decOutputs['logits'];
      if (logits == null) {
        for (final v in decOutputs.values) v?.dispose();
        break;
      }

      final logitsList = await logits.asList() as List;
      for (final v in decOutputs.values) v?.dispose();

      // greedy decoding：取 logits 最后一个时间步的 argmax
      final vocabSize = logitsList.length;
      int bestId = 0;
      double bestVal = double.negativeInfinity;
      for (int i = 0; i < vocabSize; i++) {
        final val = (logitsList[i] as num).toDouble();
        if (val > bestVal) {
          bestVal = val;
          bestId = i;
        }
      }

      if (bestId == eosTokenId) break;
      outputTokens.add(bestId);
    }

    // 清理 encoder 输出
    encoderHiddenStates.dispose();
    attentionMask.dispose();

    // Step 4: detokenize（占位）
    return _placeholderDetokenize(outputTokens.skip(1).toList());
  }

  // ──────────────────────────────────────────
  // 占位 Tokenizer（验证管线连通性用）
  // 正式版替换为 dart_sentencepiece_tokenizer
  // 加载 <appDir>/models/mt/opus-mt-zh-en/source.spm
  // ──────────────────────────────────────────
  List<int> _placeholderTokenize(String text) {
    // 非常简陋的字符级映射，只用于测试 ONNX 管线不报错
    // 实际 token id 毫无意义，翻译结果会是乱码，但 pipeline 通了就是成功
    final bytes = text.codeUnits.take(64).toList();
    return [...bytes, 0]; // 末尾加 EOS
  }

  String _placeholderDetokenize(List<int> ids) {
    // 占位：直接返回标记，表示管线已跑通
    if (ids.isEmpty) return '[empty output]';
    return '[MT OK, ids: ${ids.take(5).join(',')}…] '
        '→ 接入 sentencepiece 后显示真实翻译';
  }

  // ──────────────────────────────────────────
  // PCM 播放（写临时 WAV 文件再用系统播放器）
  // 验证阶段简单实现，正式版用 just_audio 或 audioplayers
  // ──────────────────────────────────────────
  Future<void> _playPcm(List<double> samples, int sampleRate) async {
    final tempDir = await getTemporaryDirectory();
    final wavFile = File('${tempDir.path}/glotalk_v3_tts.wav');

    final wavBytes = _floatToWav(samples, sampleRate);
    await wavFile.writeAsBytes(wavBytes);

    // 用 Android 系统意图打开 WAV（验证阶段）
    // 正式版替换为 just_audio: AudioPlayer().setFilePath(wavFile.path)
    if (Platform.isAndroid) {
      await const MethodChannel('glotalk/audio')
          .invokeMethod('playWav', {'path': wavFile.path})
          .catchError((_) {}); // 频道未注册时静默失败
    }

    // 简单等待约等于音频时长，让状态正常流转
    final durationMs = (samples.length / sampleRate * 1000).round();
    await Future.delayed(Duration(milliseconds: durationMs.clamp(500, 10000)));
  }

  // ──────────────────────────────────────────
  // 工具函数
  // ──────────────────────────────────────────

  /// 16-bit PCM bytes → Float32 [-1, 1]
  /// 与官方 streaming_asr 示例的 convertBytesToFloat32 一致
  Float32List _bytesToFloat32(Uint8List bytes) {
    final out = Float32List(bytes.length ~/ 2);
    final bd = bytes.buffer.asByteData();
    for (int i = 0; i < out.length; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// Float32 PCM → WAV 字节（16-bit mono）
  Uint8List _floatToWav(List<double> samples, int sampleRate) {
    final numSamples = samples.length;
    final dataSize = numSamples * 2;
    final buffer = BytesBuilder();

    void writeStr(String s) => buffer.add(s.codeUnits);
    void writeU32(int v) {
      final b = ByteData(4)..setUint32(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }
    void writeU16(int v) {
      final b = ByteData(2)..setUint16(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }

    // RIFF header
    writeStr('RIFF');
    writeU32(36 + dataSize);
    writeStr('WAVE');
    // fmt chunk
    writeStr('fmt ');
    writeU32(16);
    writeU16(1);         // PCM
    writeU16(1);         // mono
    writeU32(sampleRate);
    writeU32(sampleRate * 2); // byte rate
    writeU16(2);         // block align
    writeU16(16);        // bits per sample
    // data chunk
    writeStr('data');
    writeU32(dataSize);
    for (final s in samples) {
      final v = (s * 32767).clamp(-32768, 32767).toInt();
      final b = ByteData(2)..setInt16(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }
    return buffer.toBytes();
  }

  // ──────────────────────────────────────────
  // UI
  // ──────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('V3 翻译管线验证'),
        backgroundColor: const Color(0xFF0066FF),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新加载模型',
            onPressed: _pipelineState == _PipelineState.idle ||
                    _pipelineState == _PipelineState.error
                ? _loadModels
                : null,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── 模型状态栏 ──
            _buildModelStatusBar(),

            // ── 主内容区 ──
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 状态卡片
                  _buildStatusCard(),
                  const SizedBox(height: 16),

                  // 输入模式切换
                  _buildInputModeSwitch(),
                  const SizedBox(height: 12),

                  // 输入区
                  if (_useTextInput) _buildTextInputArea(),
                  if (!_useTextInput) _buildVoiceInputArea(),
                  const SizedBox(height: 24),

                  // 结果列表
                  if (_results.isNotEmpty) ...[
                    _buildSectionTitle('验证结果'),
                    ..._results.map(_buildResultCard),
                  ],

                  // 模型缺失提示
                  if (!_modelsReady) _buildModelDownloadGuide(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelStatusBar() {
    return Container(
      color: const Color(0xFF0066FF).withAlpha(20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: _modelReady.entries.map((e) {
          final ok = e.value;
          return Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  ok ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: ok ? Colors.green : Colors.grey,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  e.key,
                  style: TextStyle(
                    fontSize: 12,
                    color: ok ? Colors.green.shade700 : Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStatusCard() {
    Color cardColor;
    IconData icon;
    switch (_pipelineState) {
      case _PipelineState.error:
        cardColor = Colors.red.shade50;
        icon = Icons.error_outline;
      case _PipelineState.idle:
        cardColor = Colors.grey.shade50;
        icon = Icons.info_outline;
      case _PipelineState.recording:
        cardColor = Colors.red.shade50;
        icon = Icons.mic;
      default:
        cardColor = Colors.blue.shade50;
        icon = Icons.sync;
    }

    return Card(
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            if (_pipelineState != _PipelineState.idle &&
                _pipelineState != _PipelineState.error &&
                _pipelineState != _PipelineState.recording)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: 18, color: Colors.grey.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _pipelineState == _PipelineState.error
                    ? _errorMsg
                    : _statusMsg,
                style: TextStyle(
                  fontSize: 13,
                  color: _pipelineState == _PipelineState.error
                      ? Colors.red.shade700
                      : Colors.grey.shade700,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputModeSwitch() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, label: Text('文字输入'), icon: Icon(Icons.keyboard)),
        ButtonSegment(value: false, label: Text('语音录音'), icon: Icon(Icons.mic)),
      ],
      selected: {_useTextInput},
      onSelectionChanged: _pipelineState == _PipelineState.idle
          ? (s) => setState(() => _useTextInput = s.first)
          : null,
    );
  }

  Widget _buildTextInputArea() {
    final busy = _pipelineState != _PipelineState.idle &&
        _pipelineState != _PipelineState.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _textInputCtrl,
          maxLines: 3,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: '输入中文文本',
            hintText: '例：你好，很高兴认识你',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: (!busy && _modelsReady) ? _runTextPipeline : null,
          icon: const Icon(Icons.translate),
          label: const Text('翻译 + 播放'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0066FF),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceInputArea() {
    final isRecording = _pipelineState == _PipelineState.recording;
    final busy = _pipelineState != _PipelineState.idle &&
        _pipelineState != _PipelineState.error;

    return Column(
      children: [
        const Text(
          '按住录音，松开后自动识别并翻译',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onLongPressStart: (_) {
            if (!busy && _modelsReady) _startRecording();
          },
          onLongPressEnd: (_) {
            if (isRecording) _stopRecordingAndRun();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isRecording ? Colors.red : const Color(0xFF0066FF),
              boxShadow: isRecording
                  ? [BoxShadow(color: Colors.red.withAlpha(100), blurRadius: 20, spreadRadius: 4)]
                  : [],
            ),
            child: Icon(
              isRecording ? Icons.stop : Icons.mic,
              color: Colors.white,
              size: 36,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.grey,
        ),
      ),
    );
  }

  Widget _buildResultCard(_VerifyResult r) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 原文
            _labeledText('中文原文', r.sourceText, Colors.grey.shade800),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // 译文
            _labeledText('英文翻译', r.translatedText, const Color(0xFF0066FF)),
            const SizedBox(height: 10),
            // 耗时
            Row(
              children: [
                _timeBadge('TTS', '${r.ttsMs}ms'),
                const SizedBox(width: 8),
                _timeBadge('总计', '${r.totalMs}ms'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _labeledText(String label, String text, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(text, style: TextStyle(fontSize: 15, color: textColor)),
      ],
    );
  }

  Widget _timeBadge(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
    );
  }

  Widget _buildModelDownloadGuide() {
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '📦 模型文件下载指南',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 10),
            _guideItem('STT', 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8',
                'github.com/k2-fsa/sherpa-onnx/releases\n放入 models/stt/'),
            const SizedBox(height: 8),
            _guideItem('MT', 'opus-mt-zh-en (encoder + decoder int8)',
                'huggingface.co/onnx-community/opus-mt-zh-en\n放入 models/mt/'),
            const SizedBox(height: 8),
            _guideItem('TTS', 'vits-piper-en_US-libritts_r-medium',
                'github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models\n放入 models/tts/'),
          ],
        ),
      ),
    );
  }

  Widget _guideItem(String tag, String name, String hint) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF0066FF),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(tag, style: const TextStyle(color: Colors.white, fontSize: 10)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              Text(hint, style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────
// compute isolate 参数（TTS 在后台线程运行）
// 参考：sherpa-onnx Flutter TTS 官方示例的 compute() 用法
// ──────────────────────────────────────────────
class _TtsParams {
  final sherpa.OfflineTts tts;
  final String text;
  final int sid;
  final double speed;

  const _TtsParams({
    required this.tts,
    required this.text,
    required this.sid,
    required this.speed,
  });
}

sherpa.OfflineTtsGeneratedAudio _generateTts(_TtsParams p) {
  // 官方 TTS API：tts.generate(text, sid, speed) → audio.samples + audio.sampleRate
  return p.tts.generate(text: p.text, sid: p.sid, speed: p.speed);
}
