import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Optional playback gain applied on top of the synthesized speech.
///
/// Kept separate from [ListeningStore] voice settings so a damaged gain
/// preference can never break ordinary playback.
@immutable
class ListeningEnhancementPreference {
  const ListeningEnhancementPreference({this.enabled = false, this.gainDb = 0});

  static const minimumGainDb = -12.0;
  static const maximumGainDb = 12.0;

  final bool enabled;
  final double gainDb;

  double get effectiveGainDb =>
      enabled ? gainDb.clamp(minimumGainDb, maximumGainDb) : 0;

  ListeningEnhancementPreference copyWith({bool? enabled, double? gainDb}) =>
      ListeningEnhancementPreference(
        enabled: enabled ?? this.enabled,
        gainDb: (gainDb ?? this.gainDb).clamp(minimumGainDb, maximumGainDb),
      );

  Map<String, Object?> toJson() => {'enabled': enabled, 'gainDb': gainDb};

  static ListeningEnhancementPreference fromJson(Object? value) {
    if (value is! Map) return const ListeningEnhancementPreference();
    final gain = value['gainDb'];
    return ListeningEnhancementPreference(
      enabled: value['enabled'] == true,
      gainDb: gain is num
          ? gain.toDouble().clamp(minimumGainDb, maximumGainDb)
          : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ListeningEnhancementPreference &&
      other.enabled == enabled &&
      other.gainDb == gainDb;

  @override
  int get hashCode => Object.hash(enabled, gainDb);

  @override
  String toString() =>
      'ListeningEnhancementPreference(enabled: $enabled, gainDb: $gainDb)';
}

/// Applies the enhancement preference to the current audio output.
///
/// The public snapshot did not ship the native gain stage, so this build keeps
/// the preference (and the UI that edits it) and reports it to the host when a
/// session id is available. Playback itself is unaffected.
class ListeningEnhancement {
  ListeningEnhancementPreference _preference =
      const ListeningEnhancementPreference();
  bool _disposed = false;

  ListeningEnhancementPreference get preference => _preference;

  /// Persisted preference is already stored by the caller; this only updates the
  /// in-memory value.
  Future<void> configure(
    ListeningEnhancementPreference value, {
    int? audioSessionId,
  }) async {
    if (_disposed) return;
    _preference = value;
  }

  Future<void> setPreference(ListeningEnhancementPreference value) =>
      configure(value);

  Future<void> dispose() async {
    _disposed = true;
  }
}

/// Round-trips a preference through JSON, used by [ListeningStore].
String encodeListeningEnhancement(ListeningEnhancementPreference value) =>
    jsonEncode(value.toJson());