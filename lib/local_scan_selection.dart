import 'package:flutter/material.dart';

import 'book_documents.dart';

/// Token picker shown before a folder scan imports anything.
class LocalScanSelection extends StatefulWidget {
  const LocalScanSelection({super.key, required this.snapshot});

  final BookScanSnapshot snapshot;

  @override
  State<LocalScanSelection> createState() => _LocalScanSelectionState();
}

class _LocalScanSelectionState extends State<LocalScanSelection> {
  late final Set<String> _selected = {
    for (final entry in widget.snapshot.books) entry.token,
  };

  @override
  Widget build(BuildContext context) {
    final books = widget.snapshot.books;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择要导入的文件'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == books.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(books.map((entry) => entry.token));
              }
            }),
            child: Text(_selected.length == books.length ? '全不选' : '全选'),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: books.length,
        itemBuilder: (context, index) {
          final entry = books[index];
          final selected = _selected.contains(entry.token);
          final detail = widget.snapshot.details[entry.token];
          return CheckboxListTile(
            key: ValueKey('local-scan-entry-${entry.token}'),
            value: selected,
            onChanged: (value) => setState(() {
              if (value == true) {
                _selected.add(entry.token);
              } else {
                _selected.remove(entry.token);
              }
            }),
            title: Text(entry.name),
            subtitle: detail == null
                ? null
                : Text(
                    [
                      detail.folder,
                      if (detail.size case final size?) _formatSize(size),
                    ].join(' · '),
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
          child: FilledButton(
            key: const ValueKey('local-scan-confirm'),
            onPressed: () => Navigator.pop(context, {..._selected}),
            child: Text('导入 ${_selected.length} 个文件'),
          ),
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
  }
}