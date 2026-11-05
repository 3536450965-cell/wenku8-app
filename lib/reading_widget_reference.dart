import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'reading_widget_reference_capture.dart';
import 'reading_widget_snapshot.dart';

export 'reading_widget_reference_capture.dart'
    show
        ReadingDesktopSize,
        renderReadingDesktopCard,
        renderReadingDesktopCards,
        warmReadingDesktopImages;

/// Human-readable progress line for the daily reading goal.
String readingGoalCaption(int goal, int? todaySeconds) {
  final read = (todaySeconds ?? 0) ~/ 60;
  if (goal <= 0) return '按自己的节奏阅读';
  if (read >= goal) return '已达成今天的 $goal 分钟目标';
  return '今天读了 $read 分钟，还差 ${goal - read} 分钟';
}

/// In-app preview of a home-screen card.
///
/// The preview uses exactly the pixels the host extension receives, so the
/// settings page and the home screen cannot drift apart.
class ReadingDesktopCard extends StatefulWidget {
  const ReadingDesktopCard({
    super.key,
    required this.data,
    required this.size,
    required this.brightness,
    this.quoteText,
    this.quoteSource = '',
    this.quoteCount = 0,
  });

  final ReadingWidgetSnapshot data;
  final ReadingDesktopSize size;
  final Brightness brightness;
  final String? quoteText;
  final String quoteSource;
  final int quoteCount;

  @override
  State<ReadingDesktopCard> createState() => _ReadingDesktopCardState();
}

class _ReadingDesktopCardState extends State<ReadingDesktopCard> {
  Future<Uint8List>? _bytes;
  Object? _signature;

  Object _currentSignature() => (
    widget.data.toJson(),
    widget.size,
    widget.brightness,
    widget.quoteText,
    widget.quoteSource,
  );

  Future<Uint8List> _render() => renderReadingDesktopCard(
    widget.data,
    widget.size,
    brightness: widget.brightness,
    paintQuote: (widget.quoteText ?? '').trim().isNotEmpty,
    quoteText: widget.quoteText,
    quoteSource: widget.quoteSource,
    quoteCount: widget.quoteCount,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final signature = _currentSignature();
    if (_bytes == null || signature != _signature) {
      _signature = signature;
      _bytes = _render();
    }
  }

  @override
  void didUpdateWidget(ReadingDesktopCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _currentSignature();
    if (signature != _signature) {
      _signature = signature;
      _bytes = _render();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.size.width / widget.size.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              );
            }
            return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
          },
        ),
      ),
    );
  }
}