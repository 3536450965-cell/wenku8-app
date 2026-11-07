import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'custom_source.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'wenku8_page.dart' show Wenku8Page;

/// Opens the custom source page: any site that behaves like a classic Chinese
/// novel site, driven by a URL the reader supplies.
Future<bool?> openCustomSource(
  BuildContext context,
  LocalBookStore books, {
  LibraryState? state,
}) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    builder: (_) => CustomSourcePage(books: books, state: state),
  ),
);

class CustomSourcePage extends StatefulWidget {
  const CustomSourcePage({super.key, required this.books, this.state});

  final LocalBookStore books;
  final LibraryState? state;

  @override
  State<CustomSourcePage> createState() => _CustomSourcePageState();
}

class _CustomSourcePageState extends State<CustomSourcePage> {
  static const String _baseKey = 'custom_source_base';

  final _base = TextEditingController();
  final _query = TextEditingController();

  CustomSource? _source;
  List<CustomBook> _results = const [];
  CustomBook? _book;
  List<CustomVolume> _volumes = const [];
  final Set<String> _selected = <String>{};
  String? _error;
  String? _hint;
  bool _busy = false;

  bool _downloading = false;
  bool _cancelRequested = false;
  int _done = 0;
  int _total = 0;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _base.text = CustomSource.defaultBaseUrl;
    _loadBase();
  }

  Future<void> _loadBase() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_baseKey);
    if (saved != null && saved.trim().isNotEmpty && mounted) {
      setState(() => _base.text = saved);
    }
  }

  @override
  void dispose() {
    _source?.dispose();
    _base.dispose();
    _query.dispose();
    super.dispose();
  }

  CustomSource _client() {
    final existing = _source;
    if (existing != null) return existing;
    final created = CustomSource(baseUrl: _base.text);
    _source = created;
    return created;
  }

  void _say(String message) {
    if (!mounted) return;
    setState(() => _hint = message);
  }

  Future<void> _persistBase(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_baseKey, value.trim());
  }

  /// A pasted book link skips the search step entirely.
  bool _looksLikeLink(String value) =>
      value.startsWith('http') ||
      RegExp(r'^[\w.-]+\.[a-z]{2,}/\S*').hasMatch(value);

  Future<void> _submit() async {
    final raw = _query.text.trim();
    if (raw.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
      _book = null;
      _volumes = const [];
      _results = const [];
      _selected.clear();
    });
    try {
      await _persistBase(_base.text);
      final source = _client();
      if (_looksLikeLink(raw)) {
        final url = raw.startsWith('http') ? raw : 'https://$raw';
        await _openBook(CustomBook(url: url, title: ''));
        return;
      }
      final books = await source.search(raw);
      if (!mounted) return;
      setState(() {
        _results = books;
        _hint = books.isEmpty
            ? '没搜到。可以在浏览器里打开书籍页，把链接粘贴到这里。'
            : '找到 ${books.length} 本。';
      });
    } on CustomSourceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBook(CustomBook entry) async {
    setState(() {
      _busy = true;
      _error = null;
      _hint = '正在读取书籍信息…';
      _selected.clear();
    });
    try {
      final source = _client();
      final book = await source.book(entry.url);
      final volumes = await source.catalog(entry.url);
      if (!mounted) return;
      final chapters = volumes.fold<int>(
        0,
        (sum, volume) => sum + volume.chapters.length,
      );
      setState(() {
        _book = book;
        _volumes = volumes;
        _hint = '${book.title} · ${volumes.length} 卷 $chapters 章';
      });
    } on CustomSourceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<CustomVolume> get _pickedVolumes {
    if (_selected.isEmpty) return _volumes;
    return _volumes
        .where((volume) => _selected.contains(volume.title))
        .toList(growable: false);
  }

  int get _pickedChapters => _pickedVolumes.fold<int>(
    0,
    (sum, volume) => sum + volume.chapters.length,
  );

  Future<void> _download() async {
    final book = _book;
    if (book == null || _downloading) return;
    final volumes = _pickedVolumes;
    if (volumes.isEmpty) {
      _say('先选一卷。');
      return;
    }
    setState(() {
      _downloading = true;
      _cancelRequested = false;
      _error = null;
      _done = 0;
      _total = volumes.fold<int>(0, (sum, v) => sum + v.chapters.length);
      _status = '准备中…';
    });
    final source = _client();
    try {
      final contents = <String, CustomChapterContent>{};
      for (final volume in volumes) {
        for (final chapter in volume.chapters) {
          if (_cancelRequested) break;
          try {
            final content = await source.chapter(chapter);
            contents[chapter.url] = content;
          } on CustomSourceException {
            // A single broken chapter must not lose the whole book.
          }
          if (!mounted) return;
          setState(() {
            _done++;
            _status = chapter.title;
          });
          await Future<void>.delayed(const Duration(milliseconds: 220));
        }
        if (_cancelRequested) break;
      }
      if (_cancelRequested) {
        _say('已取消。');
        return;
      }
      setState(() => _status = '正在打包 epub…');
      final images = <String, Uint8List>{};
      var imageIndex = 0;
      final chapters = volumes
          .expand((volume) => volume.chapters)
          .toList(growable: false);
      for (final chapter in chapters) {
        final content = contents[chapter.url];
        if (content == null || content.images.isEmpty) continue;
        final rewritten = <String>[];
        for (final url in content.images) {
          if (imageIndex >= 80) break;
          final bytes = await source.image(url);
          if (bytes == null) continue;
          imageIndex++;
          final ext = url.toLowerCase().contains('.png') ? 'png' : 'jpg';
          final name = 'image-$imageIndex.$ext';
          images[name] = bytes;
          rewritten.add(name);
        }
        if (rewritten.isNotEmpty) {
          contents[chapter.url] = CustomChapterContent(
            title: content.title,
            paragraphs: content.paragraphs,
            images: rewritten,
          );
        }
      }
      Uint8List? cover;
      final coverUrl = book.coverUrl;
      if (coverUrl != null) cover = await source.image(coverUrl);
      final bytes = source.epub(
        book: book,
        volumes: volumes,
        contents: contents,
        cover: cover,
        images: images,
      );
      final directory = await getTemporaryDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${directory.path}/custom-$stamp.epub');
      await file.writeAsBytes(bytes, flush: true);
      setState(() => _status = '正在导入书架…');
      final novel = await widget.books.importFile('${book.title}.epub', file.path);
      try {
        await file.delete();
      } catch (_) {
        // Leaving the temp file behind is harmless.
      }
      if (!mounted) return;
      setState(() {
        _hint = '已导入《${novel.title}》：${contents.length} 章'
            '${images.isEmpty ? '' : '、${images.length} 张图'}';
      });
    } on CustomSourceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '下载失败：$error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义书源'),
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _field(
            controller: _base,
            label: '书源地址',
            hint: 'https://www.52bqg.com',
            keyboard: TextInputType.url,
          ),
          const SizedBox(height: 10),
          _field(
            controller: _query,
            label: '书名 / 编号 / 书籍链接',
            hint: '例如 转生史莱姆，或粘贴 https://…/book_12345/',
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(CupertinoIcons.search, size: 18),
                  label: Text(_busy ? '正在处理…' : '搜索 / 打开'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _results = const [];
                    _book = null;
                    _volumes = const [];
                    _selected.clear();
                    _error = null;
                    _hint = null;
                  });
                },
                child: const Text('清空'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.5,
              ),
            ),
          ],
          if (_hint != null) ...[
            const SizedBox(height: 10),
            Text(
              _hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('搜索结果', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final result in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(result.title, maxLines: 2),
                trailing: const Icon(CupertinoIcons.chevron_forward, size: 16),
                onTap: _downloading ? null : () => _openBook(result),
              ),
          ],
          if (_volumes.isNotEmpty) ...[
            const Divider(height: 28),
            Text('目录', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              _selected.isEmpty
                  ? '不选就下载全部 ${_pickedChapters} 章。'
                  : '已选 ${_selected.length} 卷 ${_pickedChapters} 章。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            for (final volume in _volumes)
              CheckboxListTile(
                value: _selected.contains(volume.title),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(volume.title, maxLines: 2),
                subtitle: Text('${volume.chapters.length} 章'),
                onChanged: _downloading
                    ? null
                    : (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(volume.title);
                        } else {
                          _selected.remove(volume.title);
                        }
                      }),
              ),
            const SizedBox(height: 8),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _total == 0 ? null : _done / _total,
                minHeight: 2,
              ),
              const SizedBox(height: 6),
              Text(
                '$_done / $_total 章 · $_status',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => setState(() => _cancelRequested = true),
                child: const Text('取消'),
              ),
            ] else
              FilledButton.icon(
                onPressed: _download,
                icon: const Icon(CupertinoIcons.arrow_down_circle, size: 18),
                label: Text('下载 $_pickedChapters 章并导入'),
              ),
          ],
          const SizedBox(height: 24),
          Text(
            '说明：自定义书源不内置任何站点规则，会在你填的站点上自动识别搜索框、'
            '目录和正文；遇到反爬或需要登录的站点，直接在浏览器里复制书籍链接粘贴到上面即可。'
            '请只用于自己有权阅读的内容。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) =>
                    Wenku8Page(books: widget.books, state: widget.state),
              ),
            ),
            child: const Text('回到轻小说文库'),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboard,
    ValueChanged<String>? onSubmitted,
  }) => TextField(
    controller: controller,
    keyboardType: keyboard,
    autocorrect: false,
    enableSuggestions: false,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );
}