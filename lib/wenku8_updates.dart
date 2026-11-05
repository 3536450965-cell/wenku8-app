import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'local_books.dart';
import 'wenku8_index.dart';
import 'wenku8_source.dart';

/// A shelf book whose remote catalog is longer than the local copy.
class Wenku8UpdateNotice {
  const Wenku8UpdateNotice({
    required this.book,
    required this.id,
    required this.localChapters,
    required this.remoteChapters,
  });

  final Novel book;
  final String id;
  final int localChapters;
  final int remoteChapters;

  int get newChapters =>
      remoteChapters > localChapters ? remoteChapters - localChapters : 0;
}

/// Checks shelf books against the Wenku8 catalog so the shelf can show an
/// update hint without the reader having to open the source page.
class Wenku8Updates extends ChangeNotifier {
  Wenku8Updates({required this.books, Wenku8Client? client})
    : _client = client ?? Wenku8Client() {
    instance = this;
  }

  /// The watcher owned by the shelf, so other pages can trigger a check.
  static Wenku8Updates? instance;

  final LocalBookStore books;
  final Wenku8Client _client;

  List<Wenku8UpdateNotice> notices = const [];
  bool checking = false;
  String? error;
  DateTime? checkedAt;

  bool get hasUpdates => notices.isNotEmpty;

  /// Runs a bounded check: at most [limit] books, one catalog request each.
  Future<void> check({int limit = 20, bool force = false}) async {
    if (checking) return;
    if (!force && checkedAt != null) {
      final age = DateTime.now().difference(checkedAt!);
      if (age.inMinutes < 10) return;
    }
    checking = true;
    error = null;
    notifyListeners();
    final found = <Wenku8UpdateNotice>[];
    try {
      final shelf = books.books;
      final pending = <Novel>[];
      for (final book in shelf) {
        if (pending.length >= limit) break;
        pending.add(book);
      }
      final index = await _indexOrNull();
      var consecutiveFailures = 0;
      for (final book in pending) {
        final id = _sourceId(book, index);
        if (id == null) continue;
        if (consecutiveFailures >= 2) break;
        try {
          final volumes = await _client.catalog(id);
          final remote = volumes.fold<int>(
            0,
            (sum, volume) => sum + volume.chapters.length,
          );
          consecutiveFailures = 0;
          if (remote > book.chapterCount) {
            found.add(
              Wenku8UpdateNotice(
                book: book,
                id: id,
                localChapters: book.chapterCount,
                remoteChapters: remote,
              ),
            );
          }
        } catch (_) {
          // Offline or rate limited: stop after two misses instead of waiting
          // through the whole shelf.
          consecutiveFailures++;
        }
      }
      notices = List.unmodifiable(found);
      checkedAt = DateTime.now();
    } catch (failure) {
      error = '$failure';
    }
    checking = false;
    notifyListeners();
  }

  Future<Wenku8Index?> _indexOrNull() async {
    try {
      return await Wenku8Index.load();
    } catch (_) {
      return null;
    }
  }

  /// New downloads carry `wenku8:<id>`; older ones are matched by exact title.
  String? _sourceId(Novel book, Wenku8Index? index) {
    final source = book.sourceId;
    if (source != null && source.startsWith('wenku8:')) {
      final id = source.substring('wenku8:'.length).trim();
      if (id.isNotEmpty) return id;
    }
    if (index == null) return null;
    final title = book.title.trim();
    if (title.isEmpty) return null;
    for (final entry in index.search(title, limit: 8)) {
      if (entry.title.trim() == title) return '${entry.id}';
    }
    return null;
  }
}