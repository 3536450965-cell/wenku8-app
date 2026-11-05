import 'package:flutter/material.dart';

import 'book_documents.dart';
import 'local_book_scanner.dart';

/// Folder scan hub: shows progress, the last result and the warnings.
class LocalScanPage extends StatefulWidget {
  const LocalScanPage({
    super.key,
    required this.documents,
    required this.changes,
    required this.isBusy,
    required this.progress,
    required this.result,
    required this.failure,
    required this.onScan,
  });

  final BookDocuments documents;
  final Listenable changes;
  final bool Function() isBusy;
  final (int, int)? Function() progress;
  final LocalScanResult? Function() result;
  final String? Function() failure;
  final Future<void> Function(BuildContext context) onScan;

  @override
  State<LocalScanPage> createState() => _LocalScanPageState();
}

class _LocalScanPageState extends State<LocalScanPage> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('扫描书架文件夹')),
      body: AnimatedBuilder(
        animation: widget.changes,
        builder: (context, _) {
          final busy = widget.isBusy();
          final progress = widget.progress();
          final result = widget.result();
          final failure = widget.failure();
          final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.7);
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '读取书架文件夹中的 TXT / EPUB / MOBI，已导入的文件会被跳过。',
                style: muted,
              ),
              const SizedBox(height: 20),
              if (busy) ...[
                if (progress != null)
                  Text('正在处理 ${progress.$1} / ${progress.$2}'),
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
                const SizedBox(height: 20),
              ],
              if (failure case final message?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    message,
                    style: TextStyle(color: scheme.error, height: 1.7),
                  ),
                ),
              if (result case final value?) ...[
                Text(value.summary, style: const TextStyle(height: 1.7)),
                for (final warning in value.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('· $warning', style: muted),
                  ),
                const SizedBox(height: 20),
              ],
              FilledButton(
                key: const ValueKey('local-scan-start'),
                onPressed: busy ? null : () => widget.onScan(context),
                child: Text(busy ? '正在扫描' : '开始扫描'),
              ),
            ],
          );
        },
      ),
    );
  }
}