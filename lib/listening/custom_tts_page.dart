import 'package:flutter/material.dart';

import 'controller.dart';
import 'custom_tts.dart';

/// Editor for the optional custom (SSML) speech service.
class CustomSpeechPage extends StatefulWidget {
  const CustomSpeechPage({
    super.key,
    required this.settings,
    required this.controller,
  });

  final CustomSpeechSettings settings;
  final ListeningController controller;

  @override
  State<CustomSpeechPage> createState() => _CustomSpeechPageState();
}

class _CustomSpeechPageState extends State<CustomSpeechPage> {
  late final _endpoint = TextEditingController(
    text: widget.settings.config?.endpoint ?? '',
  );
  late final _apiKey = TextEditingController(
    text: widget.settings.config?.apiKey ?? '',
  );
  late final _namespace = TextEditingController(
    text: widget.settings.config?.namespace ?? 'custom',
  );
  late final _voiceId = TextEditingController(
    text: widget.settings.config?.voiceId ?? '',
  );
  late final _locale = TextEditingController(
    text: widget.settings.config?.locale ?? 'zh-CN',
  );
  late final _label = TextEditingController(
    text: widget.settings.config?.label ?? '',
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    for (final controller in [
      _endpoint,
      _apiKey,
      _namespace,
      _voiceId,
      _locale,
      _label,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool clear = false}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (clear) {
        await widget.settings.save(null);
      } else {
        final config = CustomSpeechConfig(
          endpoint: _endpoint.text.trim(),
          apiKey: _apiKey.text.trim(),
          namespace: _namespace.text.trim().isEmpty
              ? 'custom'
              : _namespace.text.trim(),
          voiceId: _voiceId.text.trim(),
          locale: _locale.text.trim().isEmpty ? 'zh-CN' : _locale.text.trim(),
          label: _label.text.trim(),
        );
        if (!config.isConfigured) {
          setState(() => _error = '请填写接口地址与语音名称');
          return;
        }
        await widget.settings.save(config);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = '自定义语音设置未能保存，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('自定义语音接口')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '兼容 Microsoft SSML 的语音接口。语音仅在本机合成与缓存，接口地址、密钥都只保存在本机。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 18),
          _field(
            _endpoint,
            '接口地址',
            hint: 'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1',
          ),
          _field(_apiKey, '订阅密钥', secret: true),
          _field(_namespace, '命名空间', hint: 'custom'),
          _field(_voiceId, '语音名称', hint: 'zh-CN-XiaoxiaoNeural'),
          _field(_locale, '语言', hint: 'zh-CN'),
          _field(_label, '显示名称（可选）'),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton(
            key: const ValueKey('custom-tts-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存' : '保存'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _saving ? null : () => _save(clear: true),
            child: const Text('清除自定义语音'),
          ),
        ],
      ),
    );
  }
}