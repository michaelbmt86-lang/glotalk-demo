// lib/screens/verify_screen.dart
//
// 邀请码验证页面（工作手册中已验证的接口规格）
// 调用接口：POST /invite-al/verify
// Header: x-glotalk-token: glotalk2026
// Body: { "code": "ABC" }
// 成功响应: { "ok": true, "lang": "zh", "theirLang": "en" }
//
// 调试功能：
//   「Tokenizer 测试」按钮 → 调用 TranslatorService.debugTokenize()
//   打印 token ids 到屏幕，用于验证 Opus-MT 分词是否正确加载
//
// 设计原则：
//   使用现有工作手册中已验证的 API 接口，不新增接口
//   UI 参考 Telegram / WhatsApp 邀请码输入设计（简洁、大按钮）

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/translator_service.dart';

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  // ─── 状态 ────────────────────────────────────────────────
  final _codeController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  // 调试面板
  bool _debugExpanded = false;
  final _debugInputController = TextEditingController(text: '你好世界');
  String _debugOutput = '';
  bool _debugLoading = false;

  // ─── 服务器配置（来自工作手册）───────────────────────────
  static const String _baseUrl = 'https://glotalk.tech';
  static const String _accessToken = 'glotalk2026';

  // ─── 邀请码验证 ───────────────────────────────────────────
  Future<void> _verifyCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _errorMessage = '请输入邀请码');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/invite-al/verify'),
        headers: {
          'Content-Type': 'application/json',
          'x-glotalk-token': _accessToken,
        },
        body: jsonEncode({'code': code}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['ok'] == true) {
          final myLang = data['lang'] as String? ?? 'zh';
          final theirLang = data['theirLang'] as String? ?? 'en';
          if (!mounted) return;
          // 验证成功 → 跳转语言选择页
          Navigator.of(context).pushReplacementNamed(
            '/language',
            arguments: {
              'code': code,
              'myLang': myLang,
              'theirLang': theirLang,
            },
          );
        } else {
          setState(() => _errorMessage = '邀请码无效，请重新输入');
        }
      } else {
        setState(() => _errorMessage = '服务器错误 (${response.statusCode})');
      }
    } on Exception catch (e) {
      setState(() => _errorMessage = '网络错误：$e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── 调试：Tokenizer 测试 ─────────────────────────────────
  Future<void> _runTokenizerDebug() async {
    final text = _debugInputController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _debugLoading = true;
      _debugOutput = '初始化翻译器…';
    });

    try {
      final translator = TranslatorService();
      // initialize() 是幂等的，首次调用会加载 ONNX 模型
      await translator.initialize();

      setState(() => _debugOutput = '分词中…');

      final ids = await translator.debugTokenize(text);

      setState(() {
        _debugOutput = '输入文字：$text\n'
            '─────────────────────\n'
            'Token IDs（${ids.length} 个）：\n'
            '${ids.join(', ')}\n'
            '─────────────────────\n'
            '若 IDs 均为 1（<unk>），说明模型词表未加载成功\n'
            '正常情况下中文字符应有多种 ID 值';
      });
    } catch (e) {
      setState(() => _debugOutput = '错误：$e');
    } finally {
      if (mounted) setState(() => _debugLoading = false);
    }
  }

  // ─── UI ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1923),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              _buildLogo(),
              const SizedBox(height: 48),
              _buildCodeInput(),
              const SizedBox(height: 20),
              _buildVerifyButton(),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                _buildErrorMessage(),
              ],
              const SizedBox(height: 48),
              _buildDebugPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: const Color(0xFF1FEDD8),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(
            Icons.translate_rounded,
            size: 40,
            color: Color(0xFF0F1923),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'GloTalk',
          style: TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '实时跨语言语音翻译',
          style: TextStyle(
            color: Color(0xFF8899AA),
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildCodeInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '邀请码',
          style: TextStyle(
            color: Color(0xFF8899AA),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: 6,
          ),
          textAlign: TextAlign.center,
          maxLength: 6,
          decoration: InputDecoration(
            counterText: '',
            hintText: 'ABC',
            hintStyle: const TextStyle(
              color: Color(0xFF3A4A5A),
              letterSpacing: 6,
            ),
            filled: true,
            fillColor: const Color(0xFF1A2433),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: Color(0xFF1FEDD8),
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              vertical: 18,
              horizontal: 16,
            ),
          ),
          onSubmitted: (_) => _verifyCode(),
        ),
      ],
    );
  }

  Widget _buildVerifyButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _verifyCode,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1FEDD8),
          foregroundColor: const Color(0xFF0F1923),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF0F1923),
                ),
              )
            : const Text(
                '进入通话',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1A1A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _errorMessage!,
        style: const TextStyle(
          color: Color(0xFFFF6B6B),
          fontSize: 13,
        ),
      ),
    );
  }

  // ─── 调试面板 ──────────────────────────────────────────────
  Widget _buildDebugPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 折叠标题行
        GestureDetector(
          onTap: () => setState(() => _debugExpanded = !_debugExpanded),
          child: Row(
            children: [
              const Text(
                '🔧 开发者工具',
                style: TextStyle(color: Color(0xFF556677), fontSize: 12),
              ),
              const Spacer(),
              Icon(
                _debugExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 16,
                color: const Color(0xFF556677),
              ),
            ],
          ),
        ),
        if (_debugExpanded) ...[
          const SizedBox(height: 16),
          const Text(
            'Tokenizer 调试',
            style: TextStyle(
              color: Color(0xFF8899AA),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _debugInputController,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: '输入中文文字测试分词',
                    hintStyle: const TextStyle(
                      color: Color(0xFF3A4A5A),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF1A2433),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _debugLoading ? null : _runTokenizerDebug,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A3A4A),
                  foregroundColor: const Color(0xFF1FEDD8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
                child: _debugLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF1FEDD8),
                        ),
                      )
                    : const Text(
                        '运行',
                        style: TextStyle(fontSize: 13),
                      ),
              ),
            ],
          ),
          if (_debugOutput.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0A1520),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF1A2A3A),
                ),
              ),
              child: SelectableText(
                _debugOutput,
                style: const TextStyle(
                  color: Color(0xFF1FEDD8),
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.6,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _debugInputController.dispose();
    super.dispose();
  }
}
