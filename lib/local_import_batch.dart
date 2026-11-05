import 'book_documents.dart';
import 'catalog.dart';
import 'local_books.dart';

/// A non-fatal remark attached to an otherwise successful import.
typedef LocalImportNotice = ({String name, String message});

/// A selection that could not be imported at all.
typedef LocalImportFailure = ({String name, String message});

/// Outcome of one import batch.
class LocalImportReport {
  const LocalImportReport({
    required this.bookIds,
    required this.added,
    required this.existing,
    this.failures = const [],
    this.notices = const [],
  });

  final List<int> bookIds;
  final int added;
  final int existing;
  final List<LocalImportFailure> failures;
  final List<LocalImportNotice> notices;

  bool get isEmpty => total == 0;

  int get total => added + existing + failures.length;

  String get summary {
    final parts = <String>[];
    if (added > 0) parts.add('新增 $added 本');
    if (existing > 0) parts.add('$existing 本已在书库');
    if (failures.isNotEmpty) parts.add('$failures 项未导入'.replaceFirst('$failures', '${failures.length}'));
    final head = parts.isEmpty ? '没有需要导入的文件' : '已导入 ${added + existing} 本';
    final detail = parts.isEmpty ? '' : '（${parts.join('，')}）';
    final tail = [
      if (notices.isNotEmpty) '${notices.length} 项需要了解',
      if (failures.isNotEmpty) '失败 ${failures.length} 项',
    ];
    return tail.isEmpty ? '$head$detail' : '$head$detail，${tail.join('，')}';
  }
}

/// One group of imported files that look like the volumes of a single series.
class LocalImportGroup {
  const LocalImportGroup({
    required this.seed,
    required this.title,
    required this.volumes,
    this.targetId,
    this.needsTarget = false,
  });

  /// Book id used as the stable identity of this group in the UI.
  final int seed;
  final String title;
  final List<({int bookId, String title})> volumes;

  /// Existing series this group would join, if any.
  final int? targetId;

  /// Whether the user must pick an existing series first.
  final bool needsTarget;
}

/// Groups freshly imported books that look like volumes of one series.
List<LocalImportGroup> localImportGroups(
  LocalBookStore books,
  List<int> bookIds,
) {
  final buckets = <String, List<({int bookId, String title, int index})>>{};
  for (final id in bookIds.toSet()) {
    final book = books.book(id);
    if (book == null || books.seriesFor(id) != null) continue;
    final parsed = _parseVolume(book.title);
    if (parsed == null) continue;
    (buckets[parsed.base] ??= []).add((
      bookId: id,
      title: parsed.label,
      index: parsed.index,
    ));
  }
  final groups = <LocalImportGroup>[];
  for (final bucket in buckets.entries) {
    final volumes = bucket.value;
    if (volumes.length < 2) continue;
    volumes.sort((a, b) => a.index.compareTo(b.index));
    groups.add(
      LocalImportGroup(
        seed: volumes.first.bookId,
        title: bucket.key,
        volumes: [
          for (final volume in volumes)
            (bookId: volume.bookId, title: volume.title),
        ],
      ),
    );
  }
  groups.sort((a, b) => a.title.compareTo(b.title));
  return groups;
}

/// Imports [selections] one by one and reports per-file failures.
///
/// Durable writes are owned by the injected importers, so a failure never
/// leaves half-written records: the batch simply reports which entries need
/// another attempt.
Future<LocalImportReport> importLocalDocuments({
  required List<BookDocumentSelection> selections,
  required BookDocuments documents,
  required LocalBookStore books,
  required Future<Novel> Function(String name, String path) importFile,
  required Future<Novel> Function(BookDocumentSelection selected) importSelection,
  bool releaseSources = false,
  void Function(List<BookDocumentSelection> failed)? onCleanupFailed,
  void Function(int done, int total)? onProgress,
}) async {
  final bookIds = <int>[];
  final failures = <LocalImportFailure>[];
  var existing = 0;
  var done = 0;
  final known = {for (final book in books.books) book.title: book.id};
  onProgress?.call(0, selections.length);
  for (final selection in selections) {
    if (selection.error case final error?) {
      failures.add((name: selection.name, message: error));
    } else {
      try {
        final Novel imported = selection.originReference != null
            ? await importSelection(selection)
            : await importFile(selection.name, selection.path ?? '');
        if (known.containsKey(imported.title)) {
          existing++;
        }
        bookIds.add(imported.id);
      } catch (error) {
        failures.add((name: selection.name, message: _message(error)));
      }
    }
    done++;
    onProgress?.call(done, selections.length);
  }
  if (releaseSources && selections.isNotEmpty) {
    try {
      await documents.releaseBooks(selections);
    } catch (_) {
      onCleanupFailed?.call(selections);
    }
  }
  return LocalImportReport(
    bookIds: bookIds,
    added: bookIds.length,
    existing: existing,
    failures: failures,
  );
}

({String base, int index, String label})? _parseVolume(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return null;
  for (final pattern in _patterns) {
    final match = pattern.firstMatch(trimmed);
    if (match == null) continue;
    final base = match.group(1)?.trim() ?? '';
    if (base.isEmpty) continue;
    final index = _numberOf(match.group(2)!);
    if (index == null) continue;
    return (base: base, index: index, label: match.group(0)!.trim());
  }
  return null;
}

final _patterns = [
  RegExp(r'^(.*?)[\s_\-··]*第\s*([0-9一二三四五六七八九十百千零〇两]+)\s*[卷册部]$'),
  RegExp(r'^(.*?)[\s_\-··]*[卷册]\s*([0-9]+)$', caseSensitive: false),
  RegExp(r'^(.*?)[\s_\-··]*[Vv]ol(?:ume)?\.?\s*([0-9]+)$'),
  RegExp(r'^(.*?)[\s_\-··]*[(（]\s*([0-9]+)\s*[)）]$'),
];

const _digits = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};

int? _numberOf(String raw) {
  final digits = int.tryParse(raw);
  if (digits != null) return digits;
  var total = 0;
  var current = 0;
  for (final unit in raw.split('')) {
    final digit = _digits[unit];
    if (digit != null) {
      current = digit;
      continue;
    }
    final multiplier = switch (unit) {
      '十' => 10,
      '百' => 100,
      '千' => 1000,
      _ => null,
    };
    if (multiplier == null) return null;
    total += (current == 0 ? 1 : current) * multiplier;
    current = 0;
  }
  final value = total + current;
  return value > 0 ? value : null;
}

String _message(Object error) => switch (error) {
  FormatException(:final message) when message.isNotEmpty => message,
  _ => '导入未完成，请重试',
};