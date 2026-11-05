import 'book_documents.dart';
import 'local_import_batch.dart';

/// Result of one scan pass over the book folder.
class LocalScanResult {
  const LocalScanResult({
    required this.report,
    required this.total,
    required this.unchanged,
    required this.warnings,
    required this.pending,
  });

  final LocalImportReport report;
  final int total;
  final int unchanged;
  final List<String> warnings;

  /// Files that were offered but not imported (unselected or unsupported).
  final int pending;

  String get summary {
    final parts = <String>['扫描 ${total} 个文件'];
    if (report.added > 0) parts.add('新增 ${report.added} 本');
    if (report.existing > 0) parts.add('${report.existing} 本已在书库');
    if (unchanged > 0) parts.add('跳过 $unchanged 个已导入文件');
    if (pending > 0) parts.add('$pending 个未导入');
    if (report.failures.isNotEmpty) parts.add('${report.failures.length} 项失败');
    if (warnings.isNotEmpty) parts.add('${warnings.length} 条提示');
    return parts.join('，');
  }
}

/// Imports the selected entries of a folder snapshot.
///
/// [importSource] receives a staged selection per file, so the caller keeps
/// ownership of durable writes and of the category batch. [current] lets the
/// caller stop a scan once the page is gone or the app is backgrounded.
Future<LocalScanResult> scanLocalBooks({
  required BookDocuments documents,
  required BookScanSnapshot snapshot,
  required Set<String> selectedTokens,
  required bool linkText,
  required Future<LocalImportReport> Function(BookDocumentSelection source)
  importSource,
  required bool Function() current,
  void Function(int done, int total)? onProgress,
}) async {
  final entries = selectedTokens.isEmpty
      ? snapshot.books
      : [
          for (final entry in snapshot.books)
            if (selectedTokens.contains(entry.token)) entry,
        ];
  final bookIds = <int>[];
  final failures = <LocalImportFailure>[];
  var existing = 0;
  var done = 0;
  var stopped = false;
  onProgress?.call(0, entries.length);
  for (final entry in entries) {
    if (!current()) {
      stopped = true;
      break;
    }
    try {
      final report = await importSource(
        BookDocumentSelection.pending(name: entry.name, token: entry.token),
      );
      bookIds.addAll(report.bookIds);
      existing += report.existing;
      failures.addAll(report.failures);
    } catch (error) {
      failures.add((
        name: entry.name,
        message: error is FormatException && error.message.isNotEmpty
            ? error.message
            : '导入未完成，请重试',
      ));
    }
    done++;
    onProgress?.call(done, entries.length);
  }
  return LocalScanResult(
    report: LocalImportReport(
      bookIds: bookIds,
      added: bookIds.length,
      existing: existing,
      failures: failures,
    ),
    total: snapshot.total,
    unchanged: snapshot.unchanged,
    warnings: snapshot.warnings,
    pending: stopped ? entries.length - done : entries.length - done + (snapshot.books.length - entries.length).clamp(0, 1 << 30),
  );
}