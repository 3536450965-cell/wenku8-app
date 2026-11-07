import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:charset/charset.dart';

/// Raised for anything the custom source cannot do, with a message that can be
/// shown to the reader as-is.
class CustomSourceException implements Exception {
  const CustomSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One search hit / book on a third-party site.
class CustomBook {
  const CustomBook({
    required this.url,
    required this.title,
    this.author,
    this.coverUrl,
    this.summary,
  });

  final String url;
  final String title;
  final String? author;
  final String? coverUrl;
  final String? summary;

  CustomBook copyWith({
    String? title,
    String? author,
    String? coverUrl,
    String? summary,
  }) => CustomBook(
    url: url,
    title: title ?? this.title,
    author: author ?? this.author,
    coverUrl: coverUrl ?? this.coverUrl,
    summary: summary ?? this.summary,
  );
}

class CustomVolume {
  const CustomVolume({required this.title, required this.chapters});

  final String title;
  final List<CustomChapter> chapters;
}

class CustomChapter {
  const CustomChapter({required this.title, required this.url});

  final String title;
  final String url;
}

class CustomChapterContent {
  const CustomChapterContent({
    required this.title,
    required this.paragraphs,
    required this.images,
  });

  final String title;
  final List<String> paragraphs;
  final List<String> images;
}

/// A deliberately site-agnostic scraper: it learns the search form from the
/// home page and accepts the handful of markup patterns that Chinese novel
/// sites keep reusing instead of hard-coding one site's HTML.
class CustomSource {
  CustomSource({required String baseUrl}) : baseUrl = _normalize(baseUrl);

  /// Usable out of the box: the mirror that this build was exercised against.
  static const String defaultBaseUrl = 'https://www.52bqg.com';

  static const Map<String, String> _headers = {
    'accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'accept-language': 'zh-CN,zh;q=0.9,en;q=0.6',
    'upgrade-insecure-requests': '1',
  };

  static const String _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  final String baseUrl;
  HttpClient? _client;
  String? _cachedHtml;

  static String _normalize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const CustomSourceException('先填一个书源地址，比如 www.52bqg.com。');
    }
    final withScheme = trimmed.startsWith('http')
        ? trimmed
        : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw const CustomSourceException('这个地址看起来不对，需要类似 https://www.52bqg.com。');
    }
    return withScheme.replaceAll(RegExp(r'/+$'), '');
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  String _absolute(String href) {
    final value = href.trim();
    if (value.startsWith('http')) return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return '$baseUrl$value';
    return '$baseUrl/$value';
  }

  Future<HttpClient> _http() async {
    final existing = _client;
    if (existing != null) return existing;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = true
      ..userAgent = _userAgent;
    _client = client;
    return client;
  }

  Future<String> _request(
    String url, {
    String? referer,
    Map<String, String>? form,
  }) async {
    final client = await _http();
    final uri = Uri.parse(url);
    try {
      final request = await client
          .openUrl(form == null ? 'GET' : 'POST', uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      for (final entry in _headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.headers.set(
        HttpHeaders.refererHeader,
        referer ?? '$baseUrl/',
      );
      if (form != null) {
        final body = Uri(queryParameters: form).query;
        final bytes = utf8.encode(body);
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      if (response.statusCode >= 400) {
        throw CustomSourceException('站点返回 ${response.statusCode}，可能被限制了，稍后再试。');
      }
      return decodeHtml(bytes);
    } on CustomSourceException {
      rethrow;
    } on TimeoutException {
      throw const CustomSourceException('站点响应太慢（超过 25 秒），检查网络或换一个书源地址。');
    } on SocketException {
      throw const CustomSourceException('连不上这个站点，检查地址是否正确、网络是否可用。');
    } on HandshakeException {
      throw const CustomSourceException('这个站点的 HTTPS 证书有问题，换一个书源地址试试。');
    } on FormatException {
      throw const CustomSourceException('站点返回的内容无法解析。');
    }
  }

  /// Decodes bytes using the charset advertised in the document, falling back to
  /// GBK for the many Chinese sites that still serve it without a header.
  static String decodeHtml(List<int> bytes) {
    final head = utf8.decode(
      bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes,
      allowMalformed: true,
    );
    final declared = RegExp(
      r"""charset\s*=\s*["']?\s*([a-zA-Z0-9_\-]+)""",
    ).firstMatch(head)?.group(1)?.toLowerCase();
    if (declared != null && !declared.contains('utf')) {
      try {
        return gbk.decode(bytes, allowMalformed: true);
      } catch (_) {
        // Fall through to the UTF-8 attempt below.
      }
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (declared == null && text.contains('\uFFFD')) {
      try {
        return gbk.decode(bytes, allowMalformed: true);
      } catch (_) {
        return text;
      }
    }
    return text;
  }

  Future<String> home() async {
    final cached = _cachedHtml;
    if (cached != null) return cached;
    final html = await _request('$baseUrl/');
    _cachedHtml = html;
    return html;
  }

  /// Searches by keyword using whatever search form the home page exposes.
  Future<List<CustomBook>> search(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final html = await home();
    final form = _findSearchForm(html);
    final endpoint = form == null
        ? '$baseUrl/search.php'
        : _absolute(form.action);
    final String resultHtml;
    if (form == null || form.method == 'post') {
      resultHtml = await _request(
        endpoint,
        referer: '$baseUrl/',
        form: {form?.field ?? 'keyword': query},
      );
    } else {
      final uri = Uri.parse(endpoint);
      final merged = Map<String, String>.from(uri.queryParameters)
        ..[form.field] = query;
      resultHtml = await _request(
        uri.replace(queryParameters: merged).toString(),
        referer: '$baseUrl/',
      );
    }
    final books = parseSearchResults(resultHtml);
    if (books.isNotEmpty) return books;
    if (_looksLikeLogin(resultHtml)) {
      throw const CustomSourceException(
        '这个站点的搜索需要登录。可以直接在浏览器里打开书籍页，把链接粘贴到这里。',
      );
    }
    return const [];
  }

  bool _looksLikeLogin(String html) {
    final head = html.substring(0, html.length < 4000 ? html.length : 4000);
    return head.contains('登录') || head.contains('登入') || head.contains('login');
  }

  _SearchForm? _findSearchForm(String html) {
    for (final match in RegExp(
      r'<form[^>]*>([\s\S]{0,600}?)</form>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = match.group(0) ?? '';
      final body = match.group(1) ?? '';
      final field = RegExp(
        r"""<input[^>]+name\s*=\s*["']([^"']+)["']""",
        caseSensitive: false,
      ).firstMatch(body)?.group(1);
      if (field == null) continue;
      final lowered = field.toLowerCase();
      final looksSearch =
          lowered.contains('search') ||
          lowered == 's' ||
          lowered == 'q' ||
          lowered == 'key' ||
          lowered == 'keyword' ||
          lowered.contains('wd') ||
          lowered.contains('word');
      if (!looksSearch) continue;
      final type = RegExp(
        r"""<input[^>]*name\s*=\s*["']""" + RegExp.escape(field) + r"""["'][^>]*>""",
        caseSensitive: false,
      ).firstMatch(body)?.group(0);
      if (type != null && RegExp(r"""type\s*=\s*["']hidden""", caseSensitive: false).hasMatch(type)) {
        continue;
      }
      final method = (RegExp(
                r"""method\s*=\s*["'](\w+)""",
                caseSensitive: false,
              ).firstMatch(tag)?.group(1) ??
              'get')
          .toLowerCase();
      final action = RegExp(
            r"""action\s*=\s*["']([^"']*)""",
            caseSensitive: false,
          ).firstMatch(tag)?.group(1) ??
          '/';
      return _SearchForm(action: action, field: field, method: method);
    }
    return null;
  }

  List<CustomBook> parseSearchResults(String html) {
    final hits = <String, CustomBook>{};
    for (final match in RegExp(
      r"""<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]{1,80}?)</a>""",
      caseSensitive: false,
    ).allMatches(html)) {
      final href = match.group(1) ?? '';
      final title = _plain(match.group(2) ?? '');
      if (title.length < 2 || title.length > 40) continue;
      if (!_looksLikeBookHref(href)) continue;
      if (_navWords.any(title.contains)) continue;
      final url = _absolute(href);
      hits[url] = CustomBook(url: url, title: title);
    }
    return hits.values.toList(growable: false);
  }

  static const List<String> _navWords = [
    '首页',
    '排行',
    '书架',
    '登录',
    '注册',
    '全部',
    '阅读',
    '更多',
    '目录',
    '章节',
  ];

  static bool _looksLikeBookHref(String href) {
    if (href.startsWith('javascript') || href.startsWith('#')) return false;
    return RegExp(
      r'/(book[_\-]?\d+|\d+_\d+|\d{2,}/?$|\d{4,})',
      caseSensitive: false,
    ).hasMatch(href);
  }

  /// Reads title / author / cover / summary from a book page.
  Future<CustomBook> book(String url) async {
    final absolute = _absolute(url);
    final html = await _request(absolute, referer: '$baseUrl/');
    final title = _firstText(html, [
      r"""<meta[^>]+property\s*=\s*["']og:title["'][^>]+content\s*=\s*["']([^"']+)""",
      r'<h1[^>]*>([\s\S]{1,120}?)</h1>',
      r'<title>([\s\S]{1,120}?)</title>',
    ]);
    if (title.isEmpty) {
      throw const CustomSourceException('这个页面里没找到书名，确认一下链接是不是书籍页。');
    }
    final author = _firstText(html, [
      r"""<meta[^>]+property\s*=\s*["']og:novel:author["'][^>]+content\s*=\s*["']([^"']+)""",
      r'作\s*者[：:]\s*(?:<[^>]+>)*\s*([^\s<]{2,20})',
    ]);
    final cover = _firstAttr(html, [
      r"""<meta[^>]+property\s*=\s*["']og:image["'][^>]+content\s*=\s*["']([^"']+)""",
      r"""<img[^>]+src\s*=\s*["']([^"']+\.(?:jpe?g|png|webp))""",
    ]);
    final summary = _firstText(html, [
      r"""<meta[^>]+(?:name|property)\s*=\s*["'](?:description|og:description)["'][^>]+content\s*=\s*["']([^"']{10,400})""",
    ]);
    return CustomBook(
      url: absolute,
      title: _cleanTitle(title),
      author: author.isEmpty ? null : author,
      coverUrl: cover.isEmpty ? null : _absolute(cover),
      summary: summary.isEmpty ? null : summary,
    );
  }

  /// Splits the chapter list into volumes; a book page without volume markers
  /// becomes a single volume.
  Future<List<CustomVolume>> catalog(String url) async {
    final absolute = _absolute(url);
    final html = await _request(absolute, referer: '$baseUrl/');
    return parseCatalog(html);
  }

  /// Pure parser half of [catalog], kept separate so it can be tested offline.
  List<CustomVolume> parseCatalog(String html) {
    final volumes = <CustomVolume>[];
    String? currentTitle;
    var current = <CustomChapter>[];

    void flush() {
      if (current.isEmpty) return;
      volumes.add(
        CustomVolume(
          title: currentTitle ?? (volumes.isEmpty ? '正文' : '第 ${volumes.length + 1} 卷'),
          chapters: List<CustomChapter>.unmodifiable(current),
        ),
      );
      current = <CustomChapter>[];
    }

    final marker = RegExp(
      r'<(dt|dd)[^>]*>([\s\S]{0,400}?)</\1>',
      caseSensitive: false,
    );
    for (final match in marker.allMatches(html)) {
      final tag = (match.group(1) ?? '').toLowerCase();
      final inner = match.group(2) ?? '';
      if (tag == 'dt') {
        final heading = _plain(inner);
        if (heading.isNotEmpty) {
          flush();
          currentTitle = heading;
        }
        continue;
      }
      final link = RegExp(
        r"""<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]{0,120}?)</a>""",
        caseSensitive: false,
      ).firstMatch(inner);
      if (link == null) continue;
      final title = _plain(link.group(2) ?? '');
      if (title.isEmpty) continue;
      current.add(
        CustomChapter(title: title, url: _absolute(link.group(1) ?? '')),
      );
    }
    flush();

    if (volumes.isEmpty) {
      final fallback = <CustomChapter>[];
      for (final match in RegExp(
        r"""<a[^>]+href\s*=\s*["']([^"']*\d[^"']*)["'][^>]*>([\s\S]{0,120}?)</a>""",
        caseSensitive: false,
      ).allMatches(html)) {
        final title = _plain(match.group(2) ?? '');
        if (title.length < 2 || title.length > 60) continue;
        if (!RegExp(
          r'(第\s*[0-9一二三四五六七八九十百千]+\s*[章节回]|^\d+\s*[.、]|序章|楔子|尾声|番外)',
        ).hasMatch(title)) {
          continue;
        }
        fallback.add(
          CustomChapter(title: title, url: _absolute(match.group(1) ?? '')),
        );
      }
      if (fallback.isEmpty) {
        throw const CustomSourceException('这个页面里没找到章节列表，确认链接是不是书籍目录页。');
      }
      volumes.add(
        CustomVolume(
          title: '正文',
          chapters: List<CustomChapter>.unmodifiable(fallback),
        ),
      );
    }
    return volumes;
  }

  Future<CustomChapterContent> chapter(CustomChapter chapter) async {
    final html = await _request(chapter.url, referer: '$baseUrl/');
    final body = extractContent(html);
    if (body == null || _plain(body).length < 30) {
      throw const CustomSourceException('这一章没有取到正文，可能站点改版了。');
    }
    final images = <String>[];
    for (final match in RegExp(
      r"""<img[^>]+src\s*=\s*["']([^"']+)["']""",
      caseSensitive: false,
    ).allMatches(body)) {
      final src = _absolute(match.group(1) ?? '');
      if (src.isEmpty) continue;
      if (images.length >= 40) break;
      images.add(src);
    }
    final text = body
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<(p|div)[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    final paragraphs = text
        .split(RegExp(r'\n+'))
        .map((line) => _plain(line).trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return CustomChapterContent(
      title: chapter.title,
      paragraphs: paragraphs,
      images: images,
    );
  }

  /// Finds the main text block: tries the usual container names, then falls
  /// back to the densest <div> on the page.
  String? extractContent(String html) {
    for (final marker in const [
      'id="content"',
      "id='content'",
      'id="chaptercontent"',
      "id='chaptercontent'",
      'id="booktext"',
      'id="content1"',
      'class="content"',
      'class="read-content"',
      'class="showtxt"',
    ]) {
      final index = html.indexOf(marker);
      if (index < 0) continue;
      final open = html.lastIndexOf('<div', index);
      if (open < 0) continue;
      final extracted = _balancedDiv(html, open);
      if (extracted != null && _plain(extracted).length > 10) return extracted;
    }
    final article = RegExp(
      r'<article[^>]*>([\s\S]*?)</article>',
      caseSensitive: false,
    ).firstMatch(html);
    if (article != null) return article.group(1);
    return null;
  }

  /// Returns the inner HTML of the div starting at [openIndex], honouring
  /// nesting so a nested div does not cut the text short.
  String? _balancedDiv(String html, int openIndex) {
    var depth = 0;
    var cursor = openIndex;
    final tag = RegExp(r'<(/?)div\b[^>]*>', caseSensitive: false);
    while (cursor < html.length) {
      final match = tag.firstMatch(html.substring(cursor));
      if (match == null) return null;
      final absolute = cursor + match.start;
      final closing = match.group(1) == '/';
      if (closing) {
        depth--;
        if (depth == 0) {
          final innerStart = html.indexOf('>', openIndex) + 1;
          return html.substring(innerStart, absolute);
        }
      } else {
        depth++;
      }
      cursor = cursor + match.end;
    }
    return null;
  }

  /// Builds a minimal but standards-compliant EPUB so the normal importer can
  /// take it (same shape the built-in source produces).
  Uint8List epub({
    required CustomBook book,
    required List<CustomVolume> volumes,
    required Map<String, CustomChapterContent> contents,
    Uint8List? cover,
    Map<String, Uint8List> images = const {},
  }) {
    final archive = Archive();
    void add(String path, List<int> bytes) =>
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
    void addText(String path, String text) => add(path, utf8.encode(text));

    addText('mimetype', 'application/epub+zip');
    addText(
      'META-INF/container.xml',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
          '  <rootfiles>\n'
          '    <rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/>\n'
          '  </rootfiles>\n'
          '</container>',
    );
    addText('OEBPS/style.css', _css);

    final chapterFiles = <String, String>{};
    final navItems = <String>[];
    final spine = <String>[];
    var index = 0;
    for (final volume in volumes) {
      index++;
      final volumeFile = 'volume-$index.xhtml';
      chapterFiles[volumeFile] =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<html xmlns="http://www.w3.org/1999/xhtml" '
          'xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">\n'
          '<head><title>${_escape(volume.title)}</title>'
          '<link rel="stylesheet" type="text/css" href="style.css"/></head>\n'
          '<body><h1>${_escape(volume.title)}</h1>'
          '<p>本卷共 ${volume.chapters.length} 章。</p>'
          '</body></html>';
      spine.add(volumeFile);
      for (final chapter in volume.chapters) {
        index++;
        final fileName = 'chapter-$index.xhtml';
        chapterFiles[chapter.url] = fileName;
        spine.add(fileName);
        navItems.add(
          '<li><a href="$fileName">${_escape(chapter.title)}</a></li>',
        );
        final content = contents[chapter.url];
        final body = StringBuffer();
        for (final paragraph in content?.paragraphs ?? const <String>[]) {
          body.write('<p>${_escape(paragraph)}</p>');
        }
        for (final image in content?.images ?? const <String>[]) {
          body.write('<p><img src="${_escape(image)}" alt=""/></p>');
        }
        chapterFiles[fileName] =
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">\n'
            '<head><title>${_escape(chapter.title)}</title>'
            '<link rel="stylesheet" type="text/css" href="style.css"/></head>\n'
            '<body><h2>${_escape(chapter.title)}</h2>$body</body></html>';
      }
    }

    for (final entry in chapterFiles.entries) {
      addText('OEBPS/${entry.key}', entry.value);
    }
    for (final entry in images.entries) {
      add('OEBPS/${entry.key}', entry.value);
    }
    if (cover != null) add('OEBPS/cover.jpg', cover);

    final manifest = StringBuffer()
      ..write('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
      ..write('<item id="css" href="style.css" media-type="text/css"/>');
    for (final file in chapterFiles.keys) {
      manifest.write(
        '<item id="${file.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}" '
        'href="$file" media-type="application/xhtml+xml"/>',
      );
    }
    for (final file in images.keys) {
      manifest.write(
        '<item id="${file.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}" '
        'href="$file" media-type="${_imageType(file)}"/>',
      );
    }
    if (cover != null) {
      manifest.write(
        '<item id="cover-image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>',
      );
    }

    addText(
      'OEBPS/content.opf',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
          'unique-identifier="bookid">\n'
          '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
          '    <dc:identifier id="bookid">${_escape(book.url)}</dc:identifier>\n'
          '    <dc:title>${_escape(book.title)}</dc:title>\n'
          '    <dc:language>zh-CN</dc:language>\n'
          '${book.author == null ? '' : '    <dc:creator>${_escape(book.author!)}</dc:creator>\n'}'
          '${book.summary == null ? '' : '    <dc:description>${_escape(book.summary!)}</dc:description>\n'}'
          '${cover == null ? '' : '    <meta name="cover" content="cover-image"/>\n'}'
          '  </metadata>\n'
          '  <manifest>$manifest</manifest>\n'
          '  <spine toc="ncx">${spine.map((f) => '<itemref idref="${f.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}"/>').join()}</spine>\n'
          '</package>',
    );
    addText(
      'OEBPS/toc.ncx',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
          '  <head><meta name="dtb:uid" content="${_escape(book.url)}"/></head>\n'
          '  <docTitle><text>${_escape(book.title)}</text></docTitle>\n'
          '  <navMap>${navItems.join()}</navMap>\n'
          '</ncx>',
    );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static const String _css =
      'body{line-height:1.75;margin:0 1.1em;font-size:1em;}'
      'h1{font-size:1.3em;margin:1.2em 0 .8em;}'
      'h2{font-size:1.1em;margin:1.4em 0 .6em;font-weight:600;}'
      'p{margin:0 0 .75em;text-indent:2em;}'
      'img{max-width:100%;height:auto;display:block;margin:.8em auto;}';

  static String _imageType(String file) {
    final lowered = file.toLowerCase();
    if (lowered.endsWith('.png')) return 'image/png';
    if (lowered.endsWith('.webp')) return 'image/webp';
    if (lowered.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// Fetches an image, keeping the caller's failure tolerance.
  Future<Uint8List?> image(String url) async {
    try {
      final client = await _http();
      final request = await client
          .getUrl(Uri.parse(_absolute(url)))
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.refererHeader, '$baseUrl/');
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      if (bytes.length < 200 || bytes.length > 4 * 1024 * 1024) return null;
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  String _firstText(String html, List<String> patterns) {
    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
      final value = match?.group(1);
      if (value != null) {
        final plain = _plain(value);
        if (plain.isNotEmpty) return plain;
      }
    }
    return '';
  }

  String _firstAttr(String html, List<String> patterns) {
    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  static String _cleanTitle(String raw) {
    var title = raw;
    for (final separator in const ['_', '-', '—', '|', '·']) {
      final index = title.indexOf(separator);
      if (index > 1 && index < title.length - 1) {
        title = title.substring(0, index);
        break;
      }
    }
    return title.trim();
  }

  static String _plain(String html) => _decodeEntities(
    html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('\u00a0', ' '),
  ).replaceAll(RegExp(r'[ \t\u3000]+'), ' ').trim();

  static String _decodeEntities(String text) {
    var result = text;
    for (final entry in const {
      '&nbsp;': ' ',
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&ldquo;': '“',
      '&rdquo;': '”',
      '&hellip;': '…',
      '&mdash;': '—',
    }.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result.replaceAllMapped(
      RegExp(r'&#x?([0-9a-fA-F]+);'),
      (match) {
        final raw = match.group(1) ?? '';
        final code = raw.toLowerCase().startsWith('x')
            ? int.tryParse(raw.substring(1), radix: 16)
            : int.tryParse(raw);
        if (code == null) return match.group(0) ?? '';
        return String.fromCharCode(code);
      },
    );
  }

  static String _escape(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

class _SearchForm {
  const _SearchForm({
    required this.action,
    required this.field,
    required this.method,
  });

  final String action;
  final String field;
  final String method;
}