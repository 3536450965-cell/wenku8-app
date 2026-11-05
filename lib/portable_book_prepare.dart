import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// One converted document produced by [PortableBookPreparer].
typedef PreparedBookDocument = ({String name, String? path, String? error});

/// Turns a picked file into durable, app-owned documents.
///
/// The macOS/iOS host performs the real conversion for portable formats; this
/// class owns the staging directory, the naming pass and the platform hooks so
/// [BookDocuments] can stay a thin channel wrapper.
class PortableBookPreparer {
  PortableBookPreparer({
    required this.directory,
    required this.textCodecToken,
    required this.decodeNames,
    required this.convert,
    required this.extractKindle,
    this.extractPdf,
  });

  static const _portableExtensions = {'.epub', '.txt', '.md', '.html', '.htm'};
  static const _kindleExtensions = {'.azw3', '.azw', '.mobi', '.prc'};

  final Directory directory;
  final RootIsolateToken textCodecToken;

  /// Decodes opaque document names through the host channel.
  final Future<List<String>> Function(List<String> names) decodeNames;

  /// Host-side conversion for portable formats.
  final Future<List<PreparedBookDocument>> Function(String name, String path)
  convert;

  /// Extracts an AZW/MOBI/PRC file; returns the number of written chapters.
  final Future<int> Function(String source, String output) extractKindle;

  /// Extracts a PDF on hosts that support it.
  final Future<void> Function(String name, String source, String output)?
  extractPdf;

  /// Removes staged files from earlier runs so the temp cache cannot grow
  /// without bound.
  static Future<void> clearPreviousRuns(Directory directory) async {
    try {
      if (!await directory.exists()) return;
      await for (final entity in directory.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          /* A live import may still hold one entry; the next run retries. */
        }
      }
    } catch (_) {
      /* Unreadable temp storage is not fatal for an import. */
    }
  }

  /// Deletes staged files that are no longer referenced by a library record.
  Future<void> releasePaths(Iterable<String> paths) async {
    for (final path in paths.toSet()) {
      if (!path.startsWith(directory.path)) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        /* A still-open reader may hold the file; the next run cleans up. */
      }
    }
  }

  Future<List<PreparedBookDocument>> prepare(String name, String path) async {
    final extension = _extensionOf(name.isEmpty ? path : name);
    final runDirectory = await _runDirectory();
    final base = _stem(name.isEmpty ? path : name);
    try {
      if (_kindleExtensions.contains(extension)) {
        return await _prepareKindle(base, path, runDirectory);
      }
      if (extension == '.pdf') {
        return await _preparePdf(base, path, runDirectory);
      }
      if (_portableExtensions.contains(extension)) {
        final copied = await _copy(path, runDirectory, base, extension);
        return [(name: name, path: copied, error: null)];
      }
      // Everything else is handled by the host converter.
      return await convert(name, path);
    } catch (error) {
      return [(name: name, path: null, error: _message(error))];
    }
  }

  Future<List<PreparedBookDocument>> _prepareKindle(
    String base,
    String path,
    Directory runDirectory,
  ) async {
    final output = '${runDirectory.path}/$base.epub';
    final chapters = await extractKindle(path, output);
    if (chapters <= 0 || !File(output).existsSync()) {
      return [(name: base, path: null, error: '未能从这本电子书中提取内容')];
    }
    return [(name: '${base}.epub', path: output, error: null)];
  }

  Future<List<PreparedBookDocument>> _preparePdf(
    String base,
    String path,
    Directory runDirectory,
  ) async {
    final extract = extractPdf;
    if (extract == null) {
      return [(name: base, path: null, error: '当前版本不支持导入 PDF')];
    }
    final output = '${runDirectory.path}/$base.epub';
    await extract(base, path, output);
    if (!File(output).existsSync()) {
      return [(name: base, path: null, error: '未能从这份 PDF 中提取内容')];
    }
    return [(name: '${base}.epub', path: output, error: null)];
  }

  Future<String> _copy(
    String path,
    Directory runDirectory,
    String base,
    String extension,
  ) async {
    final target = '${runDirectory.path}/$base$extension';
    final source = File(path);
    if (source.path == target) return target;
    await source.copy(target);
    final decoded = extension == '.txt' || extension == '.md'
        ? await _decoded(target)
        : null;
    if (decoded != null) {
      final rewritten = File('${runDirectory.path}/$base.txt');
      await rewritten.writeAsBytes(decoded, flush: true);
      return rewritten.path;
    }
    return target;
  }

  /// Decodes text in a background isolate; malformed bytes are replaced rather
  /// than failing the import.
  Future<Uint8List?> _decoded(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return await Isolate.run(() {
        var text = utf8.decode(bytes, allowMalformed: true);
        if (text.trimLeft().startsWith('<')) {
          text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
        }
        return Uint8List.fromList(utf8.encode(text));
      });
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _runDirectory() async {
    final directory_ = Directory('${directory.path}/run-${DateTime.now().microsecondsSinceEpoch}');
    await directory_.create(recursive: true);
    return directory_;
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  String _stem(String name) {
    final file = name.split(RegExp(r'[/\\]')).last;
    final dot = file.lastIndexOf('.');
    final stem = (dot <= 0 ? file : file.substring(0, dot)).trim();
    final safe = stem.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return safe.isEmpty ? 'book-${math.Random().nextInt(1 << 20)}' : safe;
  }

  String _message(Object error) => switch (error) {
    FileSystemException(:final message) when message.isNotEmpty => message,
    _ => '文件转换未完成，请重试',
  };
}