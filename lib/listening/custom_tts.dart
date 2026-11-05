import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Configuration for a user-supplied, Microsoft-SSML compatible speech service.
@immutable
class CustomSpeechConfig {
  const CustomSpeechConfig({
    required this.endpoint,
    required this.apiKey,
    required this.namespace,
    required this.voiceId,
    this.locale = 'zh-CN',
    this.label = '',
  });

  /// Full SSML endpoint, for example
  /// `https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1`.
  final String endpoint;

  /// Key sent as `Ocp-Apim-Subscription-Key`.
  final String apiKey;

  /// Namespace reported to the rest of the app as the voice engine.
  final String namespace;

  /// Provider voice name, for example `zh-CN-XiaoxiaoNeural`.
  final String voiceId;

  final String locale;

  /// Optional display name for the voice picker.
  final String label;

  bool get isConfigured =>
      endpoint.trim().isNotEmpty &&
      voiceId.trim().isNotEmpty &&
      locale.trim().isNotEmpty;

  /// The voice entry this configuration represents.
  SpeechVoice get voice => SpeechVoice(
    id: voiceId,
    label: label.trim().isEmpty ? voiceId : label.trim(),
    source: ListeningSource.custom,
    locale: locale,
    engine: namespace.trim().isEmpty ? 'custom' : namespace.trim(),
  );

  CustomSpeechConfig copyWith({
    String? endpoint,
    String? apiKey,
    String? namespace,
    String? voiceId,
    String? locale,
    String? label,
  }) => CustomSpeechConfig(
    endpoint: endpoint ?? this.endpoint,
    apiKey: apiKey ?? this.apiKey,
    namespace: namespace ?? this.namespace,
    voiceId: voiceId ?? this.voiceId,
    locale: locale ?? this.locale,
    label: label ?? this.label,
  );

  Map<String, Object?> toJson() => {
    'endpoint': endpoint,
    'apiKey': apiKey,
    'namespace': namespace,
    'voiceId': voiceId,
    'locale': locale,
    'label': label,
  };

  static CustomSpeechConfig? fromJson(Object? value) {
    if (value is! Map) return null;
    final endpoint = value['endpoint'];
    final voiceId = value['voiceId'];
    if (endpoint is! String || voiceId is! String) return null;
    return CustomSpeechConfig(
      endpoint: endpoint,
      apiKey: value['apiKey'] is String ? value['apiKey'] as String : '',
      namespace: value['namespace'] is String
          ? value['namespace'] as String
          : 'custom',
      voiceId: voiceId,
      locale: value['locale'] is String ? value['locale'] as String : 'zh-CN',
      label: value['label'] is String ? value['label'] as String : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomSpeechConfig &&
      other.endpoint == endpoint &&
      other.apiKey == apiKey &&
      other.namespace == namespace &&
      other.voiceId == voiceId &&
      other.locale == locale &&
      other.label == label;

  @override
  int get hashCode =>
      Object.hash(endpoint, apiKey, namespace, voiceId, locale, label);
}

/// Persisted custom speech settings, shared by the cache and the settings page.
class CustomSpeechSettings extends ChangeNotifier {
  static const preferenceKey = 'listening.custom_speech.v1';

  CustomSpeechConfig? _config;
  bool _loaded = false;

  /// `null` until the user configures a service.
  CustomSpeechConfig? get config => _config;
  bool get loaded => _loaded;

  /// Loads the stored configuration. Safe to call repeatedly.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(preferenceKey);
      if (raw != null) {
        _config = CustomSpeechConfig.fromJson(jsonDecode(raw));
      }
    } catch (_) {
      _config = null;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Stores (or clears, when [value] is `null`) the configuration.
  Future<void> save(CustomSpeechConfig? value) async {
    _config = value != null && value.isConfigured ? value : null;
    _loaded = true;
    final preferences = await SharedPreferences.getInstance();
    if (_config == null) {
      await preferences.remove(preferenceKey);
    } else {
      await preferences.setString(preferenceKey, jsonEncode(_config!.toJson()));
    }
    notifyListeners();
  }
}

/// Thin client for a Microsoft-SSML compatible HTTP endpoint.
class CustomSpeechClient {
  CustomSpeechClient({HttpClient? httpClient})
    : _client = httpClient ?? HttpClient();

  final HttpClient _client;

  /// Synthesizes [text] into MP3 bytes using [config].
  Future<Uint8List> synthesize(
    String text,
    CustomSpeechConfig config,
    SpeechCancellation cancellation,
  ) async {
    cancellation.check();
    if (!config.isConfigured) {
      throw const SpeechFailure('自定义语音接口尚未配置');
    }
    final uri = Uri.tryParse(config.endpoint.trim());
    if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
      throw const SpeechFailure('自定义语音接口地址无效');
    }
    final request = await _client.postUrl(uri);
    cancellation.onCancel(() => request.abort());
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/ssml+xml; charset=utf-8',
    );
    request.headers.set('X-Microsoft-OutputFormat', 'audio-24khz-48kbitrate-mono-mp3');
    if (config.apiKey.trim().isNotEmpty) {
      request.headers.set('Ocp-Apim-Subscription-Key', config.apiKey.trim());
    }
    request.headers.set(HttpHeaders.userAgentHeader, 'Wenku8');
    request.add(
      utf8.encode(
        '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
        'xml:lang="${_escape(config.locale)}">'
        '<voice name="${_escape(config.voiceId)}">'
        '${_escape(text)}'
        '</voice></speak>',
      ),
    );
    final response = await request.close().timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw const SpeechFailure(
        '自定义语音接口响应超时',
        kind: SpeechFailureKind.timeout,
      ),
    );
    cancellation.check();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw SpeechFailure('自定义语音接口返回 ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      cancellation.check();
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      throw const SpeechFailure('自定义语音接口未返回音频');
    }
    return bytes;
  }

  void close() => _client.close(force: true);

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}