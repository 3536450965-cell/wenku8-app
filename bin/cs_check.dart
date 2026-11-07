import 'dart:convert';
// Offline check for the custom source parsers.
//
//   dart run bin/cs_check.dart
//
// Feeds the markup shapes that Chinese novel sites actually use into the
// parsers, so a regression shows up here instead of on the reader's phone.

import 'package:wenku8_flutter/custom_source.dart';

const String _searchHtml = '''
<html><head><title>搜索结果</title></head><body>
<form method="post" action="/search.html"><input type="text" name="s"><button>搜</button></form>
<div class="item"><a href="/book_46821/">史莱姆转生记</a> <span>作者：某人</span></div>
<div class="item"><a href="https://www.example.com/book_991/">史莱姆的日常</a></div>
<div class="item"><a href="/top/">排行榜</a></div>
</body></html>
''';

const String _catalogHtml = '''
<html><body><div id="list"><dl>
<dt>第一卷 起始之章</dt>
<dd><a href="/book_46821/1001.html">第1章 开场</a></dd>
<dd><a href="/book_46821/1002.html">第2章 出发</a></dd>
<dt>第二卷 旅途</dt>
<dd><a href="/book_46821/1003.html">第3章 相遇</a></dd>
</dl></div></body></html>
''';

const String _catalogNoVolumes = '''
<html><body><ul class="chapter">
<li><a href="/read/77/1.html">第1章 楔子</a></li>
<li><a href="/read/77/2.html">第2章 序章</a></li>
<li><a href="/read/77/3.html">第3章 尾声</a></li>
</ul></body></html>
''';

const String _chapterHtml = '''
<html><body>
<div id="content">第一段正文，讲一个开始。<br><br>第二段正文，<b>加粗</b>与&amp;符号。<div class="ads">广告</div>第三段。</div>
</body></html>
''';

const String _chapterNoId = '''
<html><body><article><p>这是 article 里的正文，长度足够通过三十个字的门槛。</p>
<p>第二段。</p><img src="/img/1.jpg"></article></body></html>
''';

void _expect(bool condition, String label) {
  print('${condition ? 'OK  ' : 'FAIL'} $label');
  if (!condition) throw StateError('failed: $label');
}

void main() {
  final source = CustomSource(baseUrl: 'www.example.com');
  _expect(source.baseUrl == 'https://www.example.com', 'base url normalised');

  final results = source.parseSearchResults(_searchHtml);
  _expect(results.length == 2, 'search keeps two book links (got ${results.length})');
  _expect(results.first.title == '史莱姆转生记', 'search title parsed');
  _expect(
    results.first.url == 'https://www.example.com/book_46821/',
    'relative link absolutised',
  );
  _expect(
    results.any((b) => b.url.contains('example.com/book_991/')),
    'absolute link kept',
  );

  final volumes = source.parseCatalog(_catalogHtml);
  _expect(volumes.length == 2, 'two volumes split (got ${volumes.length})');
  _expect(volumes.first.title == '第一卷 起始之章', 'volume title');
  _expect(volumes.first.chapters.length == 2, 'volume chapters');
  _expect(volumes[1].chapters.single.title == '第3章 相遇', 'second volume chapter');

  final flat = source.parseCatalog(_catalogNoVolumes);
  _expect(flat.length == 1 && flat.single.chapters.length == 3, 'flat chapter list');

  final content = source.extractContent(_chapterHtml);
  _expect(content != null, 'content div found');
  _expect(content!.contains('第一段正文'), 'content keeps text');
  _expect(content.contains('广告'), 'nested div does not truncate the body');

  final article = source.extractContent(_chapterNoId);
  _expect(article != null && article.contains('article 里的正文'), 'article fallback');

  final gbkBytes = <int>[0xC4, 0xE3, 0xBA, 0xC3];
  _expect(
    CustomSource.decodeHtml(gbkBytes) == '你好',
    'gbk fallback decoding',
  );
  _expect(
    CustomSource.decodeHtml(utf8.encode('<meta charset="utf-8">你好')) ==
        '<meta charset="utf-8">你好',
    'utf8 kept',
  );

  print('done');
}