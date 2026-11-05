import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Small housekeeping page: shows what the Wenku8 source leaves on disk and lets
/// the reader reclaim it without digging through the file system.
class Wenku8StoragePage extends StatefulWidget {
  const Wenku8StoragePage({super.key});

  @override
  State<Wenku8StoragePage> createState() => _Wenku8StoragePageState();
}

class _Wenku8StoragePageState extends State<Wenku8StoragePage> {
  bool _loading = true;
  int _files = 0;
  int _bytes = 0;
  String? _note;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<List<File>> _temporaryFiles() async {
    final directory = await getTemporaryDirectory();
    if (!directory.existsSync()) return const [];
    final files = <File>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (name.endsWith('.epub') || name.startsWith('wenku8-')) {
        files.add(entity);
      }
    }
    return files;
  }

  Future<void> _measure() async {
    try {
      final files = await _temporaryFiles();
      var bytes = 0;
      for (final file in files) {
        bytes += await file.length();
      }
      if (!mounted) return;
      setState(() {
        _files = files.length;
        _bytes = bytes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _note = '$error';
      });
    }
  }

  Future<void> _clear() async {
    setState(() => _loading = true);
    try {
      final files = await _temporaryFiles();
      for (final file in files) {
        await file.delete().catchError((_) => file);
      }
      if (!mounted) return;
      setState(() => _note = '已清理 ${files.length} 个文件');
      await _measure();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _note = '$error';
      });
    }
  }

  String get _size {
    if (_bytes < 1024) return '$_bytes B';
    if (_bytes < 1024 * 1024) return '${(_bytes / 1024).toStringAsFixed(1)} KB';
    return '${(_bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.7);
    return Scaffold(
      appBar: AppBar(title: const Text('存储')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text('文库书源下载时会在临时目录留一份 epub，导入书架后通常会自动删除；'
              '如果中途失败或取消，文件会留在这里。清理它不会动书架里的书。', style: muted),
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              leading: const Icon(CupertinoIcons.folder),
              title: const Text('下载临时文件'),
              subtitle: Text(
                _loading ? '正在统计…' : '$_files 个文件，共 $_size',
              ),
              trailing: FilledButton.tonal(
                onPressed: _loading || _files == 0 ? null : _clear,
                child: const Text('清理'),
              ),
            ),
          ),
          if (_note != null) ...[
            const SizedBox(height: 12),
            Text(_note!, style: muted),
          ],
        ],
      ),
    );
  }
}