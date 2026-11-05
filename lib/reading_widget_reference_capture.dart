import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reading_widget_snapshot.dart';
import 'reading_widget_skin.dart';

/// Home-screen widget families supported by the host extension.
enum ReadingDesktopSize {
  small('小 2×2', 320, 320),
  medium('中 4×2', 700, 340),
  large('大 4×4', 700, 700);

  const ReadingDesktopSize(this.label, this.width, this.height);

  final String label;
  final int width;
  final int height;
}

/// Loads any assets a card render needs. The vector-only renderer below has no
/// images, so this is a no-op kept for call-site symmetry.
Future<void> warmReadingDesktopImages(ReadingWidgetSnapshot snapshot) async {}

/// Renders one home-screen card into PNG bytes.
///
/// The original implementation painted a full Flutter widget tree off-screen.
/// This build renders an equivalent, simpler card with a canvas: paper colour,
/// today's minutes, the week's seven dots and an optional quote.
Future<Uint8List> renderReadingDesktopCard(
  ReadingWidgetSnapshot data,
  ReadingDesktopSize size, {
  required Brightness brightness,
  required bool paintQuote,
  String? quoteText,
  String? quoteSource,
  int quoteCount = 0,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final width = size.width.toDouble();
  final height = size.height.toDouble();
  final dark = brightness == Brightness.dark;
  final skin = data.skin;
  final paper = dark ? const Color(0xFF14171A) : Color(skin.paper);
  final ink = dark ? const Color(0xFFE8EAED) : Color(skin.ink);
  final muted = ink.withValues(alpha: 0.55);

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = paper,
  );

  final padding = width * 0.06;
  final todayMinutes = (data.verifiedTodaySeconds ?? 0) ~/ 60;
  final goal = data.dailyGoalMinutes;

  if (paintQuote && (quoteText?.trim().isNotEmpty ?? false)) {
    _drawText(
      canvas,
      quoteText!.trim(),
      offset: Offset(padding, padding * 2),
      maxWidth: width - padding * 2,
      style: TextStyle(
        color: ink,
        fontSize: height * 0.085,
        height: 1.45,
        fontWeight: FontWeight.w500,
      ),
      maxLines: 4,
    );
    if ((quoteSource ?? '').isNotEmpty) {
      _drawText(
        canvas,
        quoteSource!,
        offset: Offset(padding, height - padding * 2.4),
        maxWidth: width - padding * 2,
        style: TextStyle(color: muted, fontSize: height * 0.045),
        maxLines: 1,
      );
    }
  } else {
    _drawText(
      canvas,
      todayMinutes > 0 ? '$todayMinutes' : '0',
      offset: Offset(padding, padding * 1.4),
      maxWidth: width - padding * 2,
      style: TextStyle(
        color: ink,
        fontSize: height * 0.26,
        height: 1.0,
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
    );
    _drawText(
      canvas,
      goal > 0 ? '分钟 · 目标 $goal' : '分钟 · 今天',
      offset: Offset(padding, padding * 1.4 + height * 0.28),
      maxWidth: width - padding * 2,
      style: TextStyle(color: muted, fontSize: height * 0.058),
      maxLines: 1,
    );

    final dotRadius = height * 0.024;
    final dotGap = dotRadius * 2 + height * 0.028;
    final dotsTop = height * 0.62;
    final maxSeconds = data.week
        .map((day) => day.verifiedSeconds ?? 0)
        .fold<int>(1, (a, b) => b > a ? b : a);
    for (var i = 0; i < data.week.length; i++) {
      final seconds = data.week[i].verifiedSeconds ?? 0;
      final intensity = seconds == 0 ? 0.18 : 0.35 + 0.65 * (seconds / maxSeconds);
      canvas.drawCircle(
        Offset(padding + dotRadius + i * dotGap, dotsTop),
        dotRadius,
        Paint()..color = ink.withValues(alpha: intensity.clamp(0.0, 1.0)),
      );
    }

    final title = data.currentBook?.title;
    final chapter = data.currentBook?.chapter ?? '';
    if (data.showBookDetails && (title?.isNotEmpty ?? false)) {
      _drawText(
        canvas,
        [title!, chapter].where((v) => v.isNotEmpty).join(' · '),
        offset: Offset(padding, height * 0.72),
        maxWidth: width - padding * 2,
        style: TextStyle(color: ink, fontSize: height * 0.05),
        maxLines: 1,
      );
    }
  }

  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size.width, size.height);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw StateError('Unable to encode reading widget card');
      }
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// Renders every home-screen family in both appearances, keyed by
/// `<size>_<brightness>` so the native extension can pick one.
Future<Map<String, Uint8List>> renderReadingDesktopCards(
  ReadingWidgetSnapshot data,
) async {
  final images = <String, Uint8List>{};
  for (final brightness in Brightness.values) {
    for (final size in ReadingDesktopSize.values) {
      images['${size.name}_${brightness.name}'] = await renderReadingDesktopCard(
        data,
        size,
        brightness: brightness,
        paintQuote: false,
      );
    }
  }
  return images;
}

void _drawText(
  Canvas canvas,
  String text, {
  required Offset offset,
  required double maxWidth,
  required TextStyle style,
  int maxLines = 1,
}) {
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      textAlign: TextAlign.left,
      maxLines: maxLines,
      ellipsis: '…',
      fontFamily: style.fontFamily,
    ),
  )..pushStyle(
      ui.TextStyle(
        color: style.color,
        fontSize: style.fontSize,
        height: style.height,
        fontWeight: style.fontWeight,
      ),
    );
  builder.addText(text);
  final paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: maxWidth));
  canvas.drawParagraph(paragraph, offset);
  paragraph.dispose();
}