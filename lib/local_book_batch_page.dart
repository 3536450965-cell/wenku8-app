import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_books.dart';

/// Batch shelf management for local books.
Future<void> openLocalBookBatch(
  BuildContext context, {
  required LocalBookStore books,
  required LibraryState library,
  Set<int>? selected,
}) => pushNovelPage<void>(
  context,
  LocalBookBatchPage(books: books, library: library, initial: selected),
  reduceMotion: library.reduceMotion,
);

class LocalBookBatchPage extends StatefulWidget {
  const LocalBookBatchPage({
    super.key,
    required this.books,
    required this.library,
    this.initial,
  });

  final LocalBookStore books;
  final LibraryState library;
  final Set<int>? initial;

  @override
  State<LocalBookBatchPage> createState() => _LocalBookBatchPageState();
}

class _LocalBookBatchPageState extends State<LocalBookBatchPage> {
  late final Set<int> _selected = {...?widget.initial};
  bool _busy = false;

  List<Novel> get _books => widget.books.books;

  Future<void> _apply(bool onShelf) async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    var changed = 0;
    try {
      for (final id in _selected) {
        final book = widget.books.book(id);
        if (book == null) continue;
        await widget.library.setShelfMembership(id, onShelf, novel: book);
        changed++;
      }
      if (mounted) {
        showNovelFeedback(
          context,
          onShelf ? '已将 $changed 本加入书架' : '已将 $changed 本移出书架',
        );
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '批量整理未完成，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final books = _books;
    return Scaffold(
      appBar: AppBar(
        title: const Text('批量整理本地书'),
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    if (_selected.length == books.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(books.map((book) => book.id));
                    }
                  }),
            child: Text(_selected.length == books.length ? '全不选' : '全选'),
          ),
        ],
      ),
      body: books.isEmpty
          ? Center(
              child: Text(
                '书库中还没有本地书',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              itemCount: books.length,
              itemBuilder: (context, index) {
                final book = books[index];
                return CheckboxListTile(
                  key: ValueKey('local-batch-${book.id}'),
                  value: _selected.contains(book.id),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selected.add(book.id);
                          } else {
                            _selected.remove(book.id);
                          }
                        }),
                  title: Text(book.title),
                  subtitle: book.author.trim().isEmpty
                      ? null
                      : Text(
                          book.author,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('local-batch-unshelve'),
                  onPressed: _busy || _selected.isEmpty
                      ? null
                      : () => _apply(false),
                  child: const Text('移出书架'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('local-batch-shelve'),
                  onPressed: _busy || _selected.isEmpty
                      ? null
                      : () => _apply(true),
                  child: Text('加入书架 · ${_selected.length}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}