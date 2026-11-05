import 'package:flutter/material.dart';

import 'enhancement.dart';

/// Gain controls embedded in the listening settings sheet.
class ListeningEnhancementSettings extends StatefulWidget {
  const ListeningEnhancementSettings({
    super.key,
    required this.enhancement,
    required this.onChanged,
  });

  final ListeningEnhancement enhancement;
  final ValueChanged<ListeningEnhancementPreference> onChanged;

  @override
  State<ListeningEnhancementSettings> createState() =>
      _ListeningEnhancementSettingsState();
}

class _ListeningEnhancementSettingsState
    extends State<ListeningEnhancementSettings> {
  late ListeningEnhancementPreference _value = widget.enhancement.preference;

  void _commit(ListeningEnhancementPreference next) {
    setState(() => _value = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('音量增强')),
            Switch(
              key: const ValueKey('listening-enhancement-toggle'),
              value: _value.enabled,
              onChanged: (enabled) => _commit(_value.copyWith(enabled: enabled)),
            ),
          ],
        ),
        Text(
          _value.enabled
              ? '在合成语音上叠加 ${_value.gainDb.toStringAsFixed(1)} dB'
              : '保持原始响度',
          style: muted,
        ),
        if (_value.enabled) ...[
          const SizedBox(height: 4),
          Slider(
            key: const ValueKey('listening-enhancement-gain'),
            min: ListeningEnhancementPreference.minimumGainDb,
            max: ListeningEnhancementPreference.maximumGainDb,
            divisions: 24,
            value: _value.gainDb,
            label: '${_value.gainDb.toStringAsFixed(1)} dB',
            onChanged: (gain) => _commit(_value.copyWith(gainDb: gain)),
          ),
        ],
      ],
    );
  }
}