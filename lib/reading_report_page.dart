import 'package:flutter/material.dart';

import 'catalog.dart';
import 'library_state.dart';
import 'reading_report_range.dart';

/// Focused reading report for one range.
///
/// The statistics page owns the charts; this page presents the same range in a
/// single scrollable report so it can be opened from the range bar directly.
class ReadingReportPage extends StatelessWidget {
  const ReadingReportPage({
    super.key,
    required this.state,
    required this.repository,
    required this.now,
    required this.initialRange,
  });

  final LibraryState state;
  final NovelRepository repository;
  final DateTime? now;
  final ReadingReportRange initialRange;

  String get _caption => initialRange.custom
      ? '${initialRange.from!.year}.${initialRange.from!.month}.${initialRange.from!.day}'
            ' — ${initialRange.until!.year}.${initialRange.until!.month}.${initialRange.until!.day}'
      : '最近 ${initialRange.period} 天';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.7);
    final today = now ?? DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('阅读报告')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(_caption, style: const TextStyle(fontSize: 20, height: 1.5)),
          const SizedBox(height: 8),
          Text('截至 ${today.year}.${today.month}.${today.day}', style: muted),
          const SizedBox(height: 24),
          Text(
            '阅读时长、读完的书目与连续阅读天数在这里汇总。'
            '统计页仍可按分类查看图表，并切换统计区间。',
            style: muted,
          ),
        ],
      ),
    );
  }
}