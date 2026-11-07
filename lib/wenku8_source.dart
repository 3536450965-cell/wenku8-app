import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:charset/charset.dart';

/// Online book source for `wenku8.net`.
///
/// The site serves GBK encoded pages without any JSON api, so everything here
/// is regex based scraping of the public pages that anonymous visitors can
/// already read: `/book/{id}.htm` (info), `/novel/{category}/{id}/index.htm`
/// (table of contents) and `/novel/{category}/{id}/{chapter}.htm` (text).
///
/// The scraped book is converted into an epub in memory and then handed to
/// [LocalBookStore.importFile], so the rest of the app keeps treating it as an
/// ordinary local book.
class Wenku8Exception implements Exception {
  Wenku8Exception(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 站点把整本书替换成「因版权问题…」的说明页。它必须中断整本下载，否则用户
/// 会得到一本几百章、每章一句话的假书。
class Wenku8TakedownException extends Wenku8Exception {
  Wenku8TakedownException(super.message);
}

class Wenku8Chapter {
  const Wenku8Chapter({required this.id, required this.title});

  final String id;
  final String title;
}

class Wenku8Volume {
  Wenku8Volume(this.title);

  final String title;
  final List<Wenku8Chapter> chapters = [];
}

class Wenku8Book {
  const Wenku8Book({
    required this.id,
    required this.title,
    required this.author,
    required this.category,
    required this.status,
    required this.length,
    required this.updated,
    required this.summary,
    this.coverUrl,
  });

  final String id;
  final String title;
  final String author;
  final String category;
  final String status;
  final String length;
  final String updated;
  final String summary;

  /// Cover picture on the mirror's image host, when the book page has one.
  final String? coverUrl;

  /// The library picks the parser from the file name, and
  /// `parseLocalBook` only accepts names ending in `.epub` or `.txt`, so the
  /// extension is part of this contract. The name is also clipped because iOS
  /// rejects file names longer than 255 bytes.
  String get fileName {
    var clean = title.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), ' ').trim();
    while (clean.endsWith('.')) {
      clean = clean.substring(0, clean.length - 1).trim();
    }
    if (clean.isEmpty) return 'wenku8-$id.epub';
    if (clean.length > 60) clean = clean.substring(0, 60).trim();
    return '$clean（文库）.epub';
  }
}

/// A fully scraped book, ready to be turned into an epub.
class Wenku8Download {
  Wenku8Download(
    this.book,
    this.volumes,
    this.chapters, {
    this.images = const {},
    this.skipped = const [],
    this.failed = const [],
    this.cover,
  });

  final Wenku8Book book;
  final List<Wenku8Volume> volumes;

  /// Chapter bodies in reading order, keyed by chapter id. Illustration pages
  /// have an empty body and carry their pictures in [images] instead.
  final Map<String, String> chapters;

  /// Illustration bytes per chapter id, already ordered for display.
  final Map<String, List<Wenku8Image>> images;

  /// Chapters the site served without any readable text or picture.
  final List<String> skipped;

  /// Chapters that could not be fetched at all after a retry, with the reason.
  final List<String> failed;

  /// Cover picture for the epub, when the book page had one.
  final Wenku8Image? cover;

  int get characterCount =>
      chapters.values.fold(0, (sum, body) => sum + body.length);

  int get imageCount =>
      images.values.fold(0, (sum, list) => sum + list.length);
}

/// One illustration belonging to a chapter.
class Wenku8Image {
  const Wenku8Image(this.path, this.bytes);

  /// Path inside the epub, for example `images/c125425-1.jpg`.
  final String path;
  final Uint8List bytes;

  String get mediaType {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }
}

class Wenku8Client {
  Wenku8Client({this.timeout = const Duration(seconds: 20)});

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  // 实测：.net 主站在大陆线路下把单章请求拖到 4 秒并频繁 429；.cc 镜像同一份
  // 内容（章节正文逐字节一致）只要 80-300ms 且不触发限流，所以默认先走 .cc，
  // 被限流或出错时再轮换回主站。
  static const _origins = [
    'https://www.wenku8.cc',
    'https://www.wenku8.net',
  ];

  final Duration timeout;
  static const int _downloadWorkers = 3;
  static const int _imageWorkers = 3;
  static const Duration _imageTimeout = Duration(seconds: 12);

  /// 建连单独用更短的超时：某个镜像在某些网络里根本连不上，等满 20 秒再
  /// 放弃等于把整本书拖死，6 秒内连不上就当这个域名暂时不可用。
  static const Duration _connectTimeout = Duration(seconds: 6);

  /// 站点按 **每个域名** 分窗口限流：同一个域名大约每 2 秒才放行一个章节
  /// 请求，超出就整段 429（`retry-after` 8~10 秒）。`.cc` 与 `.net` 是两套
  /// 独立配额，所以节奏按域名各记一份；同时记每个域名的往返耗时与连续失败，
  /// 慢的、连不上的自动降权——少这一步，一半请求会死在超时上。
  static const Duration _gapFloor = Duration(milliseconds: 900);
  static const Duration _gapCeiling = Duration(milliseconds: 12000);
  static const Duration _quarantine = Duration(seconds: 40);

  final Map<String, _OriginSlot> _slots = {
    for (final origin in _origins) origin: _OriginSlot(origin),
  };

  _OriginSlot? _current;

  /// 当前实际在用的域名（界面显示用）。
  String get activeOrigin =>
      _current?.origin.replaceFirst('https://www.', '') ?? '—';

  /// 本次会话触发限流的次数（界面显示用）。
  int get throttleCount =>
      _slots.values.fold<int>(0, (sum, slot) => sum + slot.throttles);

  /// 选一个最早空出来的域名，占好它的时间槽后再发请求。
  ///
  /// 等待被切成 200ms 的小段：取消要能在一瞬间生效，否则用户点「取消」
  /// 之后还得等十几秒的排期才看到反应。
  Future<_OriginSlot> _claimSlot() async {
    final now = DateTime.now();
    _OriginSlot? pick;
    for (final origin in _origins) {
      final slot = _slots[origin]!;
      if (pick == null || slot.next.isBefore(pick.next)) pick = slot;
    }
    final slot = pick!;
    final target = slot.next.isAfter(now) ? slot.next : now;
    slot.next = target.add(slot.gap);
    var left = target.difference(now);
    const tick = Duration(milliseconds: 200);
    while (left > Duration.zero) {
      _throwIfCancelled();
      final step = left > tick ? tick : left;
      await Future<void>.delayed(step);
      left -= step;
    }
    _current = slot;
    return slot;
  }

  bool Function()? _cancelCheck;

  /// 直接掐断正在飞行的连接：用户点取消时，等一个 20 秒的请求自己结束
  /// 就等于「取消没反应」。断开后 `_get` 的 catch 会走重试路径，而重试
  /// 前会先撞到 `_throwIfCancelled()`，于是几百毫秒内就退出。
  void abortInflight() {
    _client?.close(force: true);
    _client = null;
  }

  void _throwIfCancelled() {
    if (_cancelCheck?.call() ?? false) throw Wenku8Exception('已取消。');
  }

  /// 一次成功：清失败计数，节奏按倍率往回收（快降快升，不会卡在慢值上）。
  void _praise(_OriginSlot slot, Duration elapsed) {
    slot.requests++;
    slot.failures = 0;
    slot.blockedUntil = null;
    final ms = elapsed.inMilliseconds.toDouble();
    slot.ema = slot.ema == 0 ? ms : slot.ema * 0.7 + ms * 0.3;
    final faster = Duration(
      milliseconds: (slot.gap.inMilliseconds * 0.82).round(),
    );
    slot.gap = faster < _gapFloor ? _gapFloor : faster;
  }

  /// 429：只惩罚这个域名（按 `retry-after` 整段冷却 + 间隔翻倍），不动别的域名。
  void _throttle(_OriginSlot slot, int milliseconds) {
    slot.throttles++;
    final until = DateTime.now().add(
      Duration(milliseconds: milliseconds.clamp(3000, 20000)),
    );
    final doubled = Duration(milliseconds: slot.gap.inMilliseconds * 2);
    slot.gap = doubled > _gapCeiling ? _gapCeiling : doubled;
    slot.blockedUntil = until;
    if (slot.next.isBefore(until)) slot.next = until;
  }

  /// 网络错误/超时：连续失败就先把这个域名隔离一段时间，别继续往死域名上撞。
  void _fail(_OriginSlot slot) {
    slot.failures++;
    final slower = Duration(
      milliseconds: (slot.gap.inMilliseconds * 1.6).round(),
    );
    slot.gap = slower > _gapCeiling ? _gapCeiling : slower;
    if (slot.failures >= 2) {
      final until = DateTime.now().add(_quarantine);
      slot.blockedUntil = until;
      if (slot.next.isBefore(until)) slot.next = until;
      slot.failures = 0;
    }
  }

  // 插图在 img.wenku8.com，与正文页不是同一个限流桶，单独限速即可，
  // 否则一本插图多的书会被正文窗口拖成半小时。
  Duration _imagePace = const Duration(milliseconds: 220);
  DateTime _nextImageSlot = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _waitImageSlot() async {
    final now = DateTime.now();
    final target = _nextImageSlot.isAfter(now) ? _nextImageSlot : now;
    _nextImageSlot = target.add(_imagePace);
    final wait = target.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  final Map<String, String> _categories = {};
  HttpClient? _client;
  String? _origin;

  static String? parseId(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(text)) return text;
    final match = RegExp(r'/(?:book|novel)/[^/]*?/?(\d+)(?:\.htm)?').firstMatch(
      text,
    );
    if (match != null) return match.group(1);
    final loose = RegExp(r'(\d{2,})').firstMatch(text);
    return loose?.group(1);
  }

  void _rotateOrigin(String current) {
    final index = _origins.indexOf(current);
    _origin = _origins[(index + 1) % _origins.length];
  }

  Future<HttpClient> _http() async {
    final existing = _client;
    if (existing != null) return existing;
    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..autoUncompress = false
      ..userAgent = userAgent;
    _client = client;
    return client;
  }

  Future<String> _get(String path) async {
    Object? lastError;
    var attempt = 0;
    var strikes = 0;
    while (attempt < 5 && strikes < 5) {
      _throwIfCancelled();
      _OriginSlot? slot;
      try {
        // 每个域名有独立的限流窗口，所以「排队」要按域名排：拿到时间槽的
        // 那个域名才是这次真正要用的。
        slot = await _claimSlot();
        final origin = slot.origin;
        final client = await _http();
        final request = await client.getUrl(Uri.parse('$origin$path'));
        // The site sits behind Cloudflare and rejects requests that do not look
        // like a browser; an explicit `accept-encoding` is part of that, so the
        // body is inflated here instead of by dart:io.
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(HttpHeaders.refererHeader, '$origin/');
        request.headers.set(
          HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'image/avif,image/webp,*/*;q=0.8',
        );
        request.headers.set(
          HttpHeaders.acceptLanguageHeader,
          'zh-CN,zh;q=0.9,en;q=0.8',
        );
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
        request.headers.set('upgrade-insecure-requests', '1');
        request.headers.set('sec-fetch-dest', 'document');
        request.headers.set('sec-fetch-mode', 'navigate');
        request.headers.set('sec-fetch-site', 'same-origin');
        request.headers.set('sec-fetch-user', '?1');
        final startedAt = DateTime.now();
        final response = await request.close().timeout(timeout);
        if (response.statusCode == 429 || response.statusCode == 503) {
          await response.drain<void>();
          lastError = Wenku8Exception('文库繁忙（${response.statusCode}）');
          final retryAfter =
              int.tryParse(
                response.headers.value(HttpHeaders.retryAfterHeader) ?? '',
              ) ??
              0;
          if (slot != null) _throttle(slot, retryAfter * 1000);
          strikes++;
          continue;
        }
        if (response.statusCode != 200) {
          throw Wenku8Exception('文库返回 ${response.statusCode}：$path');
        }
        final bytes = await response
            .fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))
            .timeout(timeout);
        _origin = origin;
        if (slot != null) _praise(slot, DateTime.now().difference(startedAt));
        return _decode(
          _inflate(
            bytes.takeBytes(),
            response.headers.value(HttpHeaders.contentEncodingHeader),
          ),
        );
      } catch (error) {
        lastError = error;
        _client?.close(force: true);
        _client = null;
        if (error is Wenku8Exception) rethrow;
        attempt++;
        if (slot != null) _fail(slot);
      }
    }
    if (strikes >= 5) {
      throw Wenku8Exception('文库正在限流，请稍后再试（$path）');
    }
    throw Wenku8Exception('连接文库失败：${_reason(lastError)}');
  }

  static String _reason(Object? error) {
    if (error is TimeoutException) return '请求超时';
    if (error is SocketException) return '网络不可用';
    if (error is HandshakeException) return '证书校验失败';
    return '$error';
  }

  static List<int> _inflate(List<int> bytes, String? encoding) {
    if (bytes.isEmpty) return bytes;
    final name = (encoding ?? '').toLowerCase();
    if (name.contains('gzip')) {
      return gzip.decode(bytes);
    }
    if (name.contains('deflate')) {
      try {
        return zlib.decode(bytes);
      } on FormatException {
        return ZLibDecoder(raw: true).convert(bytes);
      }
    }
    return bytes;
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return gbk.decode(bytes);
    }
  }

  Future<Wenku8Book> book(String id) async {
    final html = await _get('/book/$id.htm');
    // 书页没有 `id="title"`，`<title>` 的形式是「书名 - 作者 - 文库 - 轻小说文库」。
    final raw = _clean(_first(html, [
      RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true),
    ]));
    final title = raw.split(' - ').first.trim();
    if (title.isEmpty || title.contains('出现错误') || title.contains('不存在')) {
      // Missing ids answer with a generic error page instead of a 404, and its
      // `<title>` would otherwise look like a book called 「出现错误」.
      throw Wenku8Exception('没有找到这本书，编号 $id 可能不存在。');
    }
    final summary = _clean(_slice(html, '内容简介', '</td>'))
        .replaceFirst(RegExp(r'^[:：\s]+'), '')
        .split('\n')
        .where(
          (line) =>
              line.isNotEmpty &&
              !line.contains('推一下') &&
              !line.contains('举报'),
        )
        .join('\n');
    return Wenku8Book(
      id: id,
      title: title,
      coverUrl: _coverUrl(html, id),
      author: _field(html, '小说作者'),
      category: _field(html, '文库分类'),
      status: _field(html, '文章状态'),
      length: _field(html, '全文长度'),
      updated: _field(html, '最后更新'),
      summary: summary,
    );
  }

  /// The book page lists recommendations as well, so the cover is the first
  /// image below `img.wenku8.com/image/` whose path contains this book id.
  ///
  /// The page serves the cover over plain http and only ships the thumbnail
  /// (`3057s.jpg`) — the full-size file is a 404 — so the url is upgraded to
  /// https (iOS blocks cleartext) and the thumbnail is used as-is.
  static String? _coverUrl(String html, String id) {
    for (final match in _coverPattern.allMatches(html)) {
      final url = match.group(0);
      if (url == null || !url.contains('/$id/')) continue;
      return url.replaceFirst(RegExp('^http://'), 'https://');
    }
    return null;
  }

  static final _coverPattern = RegExp(
    r'https?://img\.wenku8\.com/image/[^"\s]+?\.(?:jpg|jpeg|png|webp)',
  );

  /// Raw substring that follows [label] up to the first occurrence of [until].
  static String _slice(String html, String label, String until) {
    final start = html.indexOf(label);
    if (start < 0) return '';
    final rest = html.substring(start + label.length);
    final end = rest.indexOf(until);
    return end < 0 ? rest : rest.substring(0, end);
  }

  /// Reads a book page, returning null when the id has no page.
  ///
  /// Used by the in-app new-book probe: GitHub's runners sit behind the site's
  /// Cloudflare challenge, so the weekly index job cannot see new books but the
  /// phone can.
  Future<Wenku8Book?> peek(String id) async {
    try {
      return await book(id);
    } on Wenku8Exception {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<Wenku8Volume>> catalog(String id) async {
    final category = await _categoryPath(id);
    final html = await _get('/novel/$category/$id/index.htm');
    final entries = <({bool header, String text, String? id})>[];
    for (final row in RegExp(
      r'<tr[^>]*>(.*?)</tr>',
      dotAll: true,
    ).allMatches(html)) {
      final cells = RegExp(
        r'<td([^>]*)>(.*?)</td>',
        dotAll: true,
      ).allMatches(row.group(1) ?? '');
      for (final cell in cells) {
        final attributes = cell.group(1) ?? '';
        final inner = cell.group(2) ?? '';
        if (attributes.contains('vcss')) {
          final name = _clean(inner);
          if (name.isEmpty) continue;
          entries.add((header: true, text: name, id: null));
        } else if (attributes.contains('ccss')) {
          final link = RegExp(
            r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            dotAll: true,
          ).firstMatch(inner);
          if (link == null) continue;
          final number = RegExp(r'(\d+)').firstMatch(link.group(1) ?? '');
          final name = _clean(link.group(2) ?? '');
          if (number == null || name.isEmpty) continue;
          entries.add((header: false, text: name, id: number.group(1)));
        }
      }
    }

    final volumes = <Wenku8Volume>[];
    Wenku8Volume? current;
    for (final entry in entries) {
      if (entry.header) {
        current = Wenku8Volume(entry.text);
        volumes.add(current);
        continue;
      }
      var volume = current;
      if (volume == null) {
        volume = Wenku8Volume('正文');
        volumes.add(volume);
        current = volume;
      }
      volume.chapters.add(Wenku8Chapter(id: entry.id!, title: entry.text));
    }
    volumes.removeWhere((volume) => volume.chapters.isEmpty);
    if (volumes.isEmpty) {
      throw Wenku8Exception('目录为空，这本书可能已下架。');
    }
    return volumes;
  }

  /// The category segment is required by the table of contents url; it is not
  /// part of the book page, so it is discovered by following the `/book/`
  /// redirect target which encodes it.
  Future<String> categoryForTest(String id) => _categoryPath(id);

  /// Diagnostic hook used by `bin/wk8_speed.dart` to time one chapter read.
  Future<({String text, List<String> images})> chapterForTest(
    String category,
    String bookId,
    String chapterId,
  ) => _chapterContent(category, bookId, chapterId);

  Future<String> _categoryPath(String id) async {
    final cached = _categories[id];
    if (cached != null) return cached;
    final html = await _get('/book/$id.htm');
    final match = RegExp(r'/novel/(\d+)/' + RegExp.escape(id)).firstMatch(
      html,
    );
    if (match != null) {
      _categories[id] = match.group(1)!;
      return match.group(1)!;
    }
    throw Wenku8Exception('无法确定这本书的分类，可能已下架。');
  }

  static final _imagePattern = RegExp(
    r'<img[^>]+src="([^"]+)"',
    caseSensitive: false,
  );

  static final _contentOpen = RegExp(
    r'<div[^>]*id="content"[^>]*>',
    caseSensitive: false,
  );

  static final _divTag = RegExp(r'<div\b[^>]*>|</div\s*>', caseSensitive: false);

  /// 正文按 div 配对切出来：插图章的正文是「图片 div」一个接一个，非贪婪的
  /// 正则会在第一张图结束后就收尾，导致整章只能拿到一张图。
  String _contentBody(String html) {
    final open = _contentOpen.firstMatch(html);
    if (open != null) {
      var depth = 1;
      for (final match in _divTag.allMatches(html, open.end)) {
        depth += match.group(0)!.startsWith('</') ? -1 : 1;
        if (depth == 0) return html.substring(open.end, match.start);
      }
      return html.substring(open.end);
    }
    return _first(html, [
      RegExp(r'<div[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)</div>', dotAll: true),
    ]);
  }

  /// Reads one chapter page. Illustration pages carry no text at all, so the
  /// image urls are returned alongside the body and fetched separately.
  Future<({String text, List<String> images})> _chapterContent(
    String categoryPath,
    String bookId,
    String chapterId,
  ) async {
    final html = await _get('/novel/$categoryPath/$bookId/$chapterId.htm');
    final body = _contentBody(html);
    final text = _plain(body);
    // 文法被版权方下架后，站点对每章都只返回一句「本书版权问题…」；如果不拦，
    // 用户会得到一本 400 多章、每章一句话的假书。
    if (text.contains('版权') &&
        (text.contains('文库不再提供') ||
            text.contains('不再提供该小说') ||
            text.contains('无法提供'))) {
      throw Wenku8TakedownException('这本书在文库已下架（版权原因），无法下载。');
    }
    final images = <String>[];
    for (final match in _imagePattern.allMatches(body)) {
      final url = match.group(1);
      if (url == null || !url.startsWith('http')) continue;
      if (!images.contains(url)) images.add(url);
    }
    return (text: text, images: images);
  }

  static const _maxImagesPerChapter = 40;
  static const _maxImageBytes = 8 * 1024 * 1024;
  static const _maxTotalImageBytes = 160 * 1024 * 1024;

  /// Illustration pages hold up to thirty pictures, so they are fetched a few
  /// at a time: one slow picture must not stall the chapter (and the progress
  /// bar) for minutes.
  Future<List<Wenku8Image>> _chapterImages(
    String chapterId,
    List<String> urls,
  ) async {
    final wanted = urls.take(_maxImagesPerChapter).toList();
    final fetched = List<Uint8List?>.filled(wanted.length, null);
    var total = 0;
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        _throwIfCancelled();
        final index = cursor++;
        if (index >= wanted.length) return;
        if (total > _maxTotalImageBytes) return;
        try {
          final bytes = await _getImage(wanted[index]);
          if (bytes.length <= _maxImageBytes) {
            total += bytes.length;
            fetched[index] = bytes;
          }
        } on Wenku8Exception {
          // A missing picture should not abort the whole book.
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    await Future.wait([
      for (var i = 0; i < _imageWorkers && i < wanted.length; i++) worker(),
    ]);
    final result = <Wenku8Image>[];
    for (var index = 0; index < fetched.length; index++) {
      final bytes = fetched[index];
      if (bytes == null) continue;
      final ext = _imageExtension(wanted[index]);
      result.add(Wenku8Image('images/c$chapterId-$index$ext', bytes));
    }
    return result;
  }

  static String _imageExtension(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['.jpg', '.jpeg', '.png', '.gif', '.webp']) {
      if (path.endsWith(ext)) return ext == '.jpeg' ? '.jpg' : ext;
    }
    return '.jpg';
  }

  Future<Uint8List> _getImage(String url) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _waitImageSlot();
        final client = await _http();
        final origin = _origin ?? _origins.first;
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(HttpHeaders.refererHeader, '$origin/');
        request.headers.set(
          HttpHeaders.acceptHeader,
          'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        );
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
        final response = await request.close().timeout(_imageTimeout);
        if (response.statusCode != 200) {
          await response.drain<void>();
          lastError = Wenku8Exception('插图返回 ${response.statusCode}');
          if (response.statusCode == 429 || response.statusCode == 503) {
            _imagePace = Duration(
              milliseconds: (_imagePace.inMilliseconds * 2).clamp(220, 3000),
            );
            _nextImageSlot = DateTime.now().add(const Duration(seconds: 2));
            _rotateOrigin(origin);
            continue;
          }
          if (attempt == 0) _rotateOrigin(origin);
          await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          continue;
        }
        final bytes = await response
            .fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))
            .timeout(_imageTimeout);
        return Uint8List.fromList(
          _inflate(
            bytes.takeBytes(),
            response.headers.value(HttpHeaders.contentEncodingHeader),
          ),
        );
      } catch (error) {
        lastError = error;
        _client?.close(force: true);
        _client = null;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw Wenku8Exception('插图下载失败：${_reason(lastError)}');
  }

  /// Downloads [volumes] one chapter at a time.
  Future<Wenku8Download> download(
    Wenku8Book book,
    List<Wenku8Volume> volumes, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // 取消要能穿透到「等排期」和「抓插图」这些长等待里，所以把判断存在
    // 客户端上，交给 `_throwIfCancelled()` 在各个等待点检查。
    _cancelCheck = isCancelled;
    try {
      return await _download(book, volumes, onProgress: onProgress);
    } finally {
      _cancelCheck = null;
    }
  }

  Future<Wenku8Download> _download(
    Wenku8Book book,
    List<Wenku8Volume> volumes, {
    void Function(int done, int total)? onProgress,
  }) async {
    final category = await _categoryPath(book.id);
    _throwIfCancelled();
    final all = [for (final volume in volumes) ...volume.chapters];
    final bodies = <String, String>{};
    final images = <String, List<Wenku8Image>>{};
    final skipped = <String>[];
    final failed = <String>[];
    var done = 0;

    // 封面先取：一本插图多的书要抓几百张图，图片站之后就开始限流，
    // 以前把封面放在最后取，结果经常空手而归（书架上就没有封面）。
    Wenku8Image? cover;
    final coverUrl = book.coverUrl;
    if (coverUrl != null) {
      for (var attempt = 0; attempt < 3 && cover == null; attempt++) {
        try {
          final bytes = await _getImage(coverUrl);
          cover = Wenku8Image('images/cover${_imageExtension(coverUrl)}', bytes);
        } on Wenku8Exception {
          if (attempt < 2) _rotateOrigin(_origin ?? _origins.first);
          await Future<void>.delayed(
            Duration(milliseconds: 600 * (attempt + 1)),
          );
        }
      }
    }

    Future<void> fetch(Wenku8Chapter entry) async {
      _throwIfCancelled();
      ({String text, List<String> images}) content;
      try {
        content = await _chapterContent(category, book.id, entry.id);
      } on Wenku8TakedownException {
        // 整本被下架：继续抓只会攒出一本全是「版权问题」的假书。
        rethrow;
      } on Wenku8Exception {
        // 用户取消不是「这一章失败」，不要睡 2 秒再重试。
        _throwIfCancelled();
        // 单章被限流或缺失不该让整本书失败：等一会儿重试一次，仍不行就跳过，
        // 最后在 Wenku8Download.failed 里如实报告。
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          content = await _chapterContent(category, book.id, entry.id);
        } on Wenku8Exception catch (error) {
          failed.add('${entry.title}（$error）');
          done++;
          onProgress?.call(done, all.length);
          return;
        }
      }
      bodies[entry.id] = content.text;
      if (content.text.isEmpty) {
        // Illustration pages have no text; only count a chapter as skipped when
        // it has neither words nor pictures. Move the bar first, so a picture
        // heavy chapter never looks like a stuck download.
        done++;
        onProgress?.call(done, all.length);
        _throwIfCancelled();
        final shots = await _chapterImages(entry.id, content.images);
        if (shots.isEmpty) {
          skipped.add(entry.title.isEmpty ? entry.id : entry.title);
          bodies.remove(entry.id);
        } else {
          images[entry.id] = shots;
        }
        return;
      }
      done++;
      onProgress?.call(done, all.length);
    }

    // 文库对连续请求限流，所以并发是「少量并行 + 每条连接之间的短间隔」，
    // 而不是一次性把几百章全发出去：429 的退避仍在 `_get` 里处理。
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= all.length) return;
        await fetch(all[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < _downloadWorkers && i < all.length; i++) worker(),
    ]);
    if (bodies.isEmpty && images.isEmpty) {
      throw Wenku8Exception('这本书没有抓到任何正文，可能整本都被限制。');
    }
    if (skipped.isNotEmpty || failed.isNotEmpty) {
      for (final volume in volumes) {
        volume.chapters.removeWhere(
          (chapter) =>
              !bodies.containsKey(chapter.id) &&
              !images.containsKey(chapter.id),
        );
      }
      volumes.removeWhere((volume) => volume.chapters.isEmpty);
    }
    return Wenku8Download(
      book,
      volumes,
      bodies,
      images: images,
      skipped: skipped,
      failed: failed,
      cover: cover,
    );
  }



  /// Builds a minimal EPUB 3 package that mirrors the one the app itself
  /// exports, so the importer recognises volumes and chapter titles.
  Uint8List epub(Wenku8Download download) {
    final book = download.book;
    final archive = Archive();
    void add(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('mimetype', 'application/epub+zip');
    add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');

    final manifest = StringBuffer();
    final imageManifest = StringBuffer();
    final spine = StringBuffer();

    final cover = download.cover;
    if (cover != null) {
      manifest.writeln(
        '    <item id="cover-image" href="${cover.path}" '
        'media-type="${cover.mediaType}" properties="cover-image"/>',
      );
      archive.addFile(
        ArchiveFile('OEBPS/${cover.path}', cover.bytes.length, cover.bytes),
      );
    }

    // 章节文件先落盘，目录最后统一生成：只有先生成全部章节路径，才能把每一章
    // 真正挂在它所属的卷下面（书库按目录层级识别「卷」，平铺会被读成单卷）。
    final volumeFiles = <List<String>>[];
    final volumeTitles = <String>[];
    final volumeChapters = <List<Wenku8Chapter>>[];
    // 全书插图按出现顺序编号。正文里的「（插图007）」这类占位符只靠这个号
    // 才能换回真图：站点在那个位置只发文字，不发 <img>。
    final orderedShots = <Wenku8Image>[];
    for (final volume in download.volumes) {
      for (final chapter in volume.chapters) {
        orderedShots.addAll(download.images[chapter.id] ?? const <Wenku8Image>[]);
      }
    }
    final registeredShots = <String>{};
    String figure(Wenku8Image image) {
      if (registeredShots.add(image.path)) {
        final id = 'img-${image.path.replaceAll(RegExp('[^A-Za-z0-9]+'), '-')}';
        imageManifest.writeln(
          '    <item id="$id" href="${image.path}" '
          'media-type="${image.mediaType}"/>',
        );
        archive.addFile(
          ArchiveFile('OEBPS/${image.path}', image.bytes.length, image.bytes),
        );
      }
      return '<p class="figure"><img src="${image.path}" alt=""/></p>';
    }

    var index = 0;
    for (final volume in download.volumes) {
      if (volume.chapters.isEmpty) continue;
      // 占位符编号按「卷」重排：同一本书每一卷都会从 插图001 重新开始。
      final volumeShots = <Wenku8Image>[];
      for (final chapter in volume.chapters) {
        volumeShots.addAll(download.images[chapter.id] ?? const <Wenku8Image>[]);
      }
      final files = <String>[];
      for (final chapter in volume.chapters) {
        index++;
        final body = download.chapters[chapter.id] ?? '';
        final shots = download.images[chapter.id] ?? const <Wenku8Image>[];
        final path = 'chapter-$index.xhtml';
        files.add(path);
        manifest.writeln(
          '    <item id="$path" href="$path" media-type="application/xhtml+xml"/>',
        );
        spine.writeln('    <itemref idref="$path"/>');
        final used = <String>{};
        final paragraphs = <String>[];
        for (final line in body.split('\n')) {
          final text = line.trim();
          if (text.isEmpty) continue;
          final placeholder = _illustrationPlaceholder.firstMatch(text);
          if (placeholder != null &&
              text.replaceAll(_illustrationPlaceholder, '').trim().isEmpty) {
            final number = int.tryParse(placeholder.group(1)!);
            Wenku8Image? matched;
            if (number != null &&
                number >= 1 &&
                number <= volumeShots.length) {
              matched = volumeShots[number - 1];
            }
            if (matched != null && used.add(matched.path)) {
              paragraphs.add(figure(matched));
              continue;
            }
          }
          paragraphs.add('<p>${_escape(text)}</p>');
        }
        final figures = StringBuffer();
        for (final image in shots) {
          if (used.contains(image.path)) continue;
          figures.writeln(figure(image));
        }
        add('OEBPS/$path', _xhtml(chapter.title, '''
<h1>${_escape(chapter.title)}</h1>
${paragraphs.join('\n')}
$figures'''));
      }
      volumeFiles.add(files);
      volumeTitles.add(
        volume.title.trim().isEmpty
            ? '第 ${volumeFiles.length} 卷'
            : volume.title.trim(),
      );
      volumeChapters.add(volume.chapters);
    }

    final navPoints = StringBuffer();
    var playOrder = 0;
    for (var v = 0; v < volumeFiles.length; v++) {
      final files = volumeFiles[v];
      final chapters = volumeChapters[v];
      playOrder++;
      navPoints.writeln('    <navPoint id="nav-v$v" playOrder="$playOrder">');
      navPoints.writeln(
        '      <navLabel><text>${_escape(volumeTitles[v])}</text></navLabel>',
      );
      // 卷本身指向该卷第一章：书库会把「有子项的目录项」当成卷，同一章后面还会
      // 被子项覆盖回真实章名，所以既分了层，第一章也不会被改名为卷名。
      navPoints.writeln('      <content src="${files.first}"/>');
      for (var c = 0; c < files.length; c++) {
        playOrder++;
        navPoints.writeln('      <navPoint id="nav-v${v}c$c" playOrder="$playOrder">');
        navPoints.writeln(
          '        <navLabel><text>${_escape(chapters[c].title)}</text></navLabel>',
        );
        navPoints.writeln('        <content src="${files[c]}"/>');
        navPoints.writeln('      </navPoint>');
      }
      navPoints.writeln('    </navPoint>');
    }

    add('OEBPS/style.css', '''
body { margin: 0 1.2em; line-height: 1.7; }
h1 { font-size: 1.4em; margin: 1.2em 0 0.8em; }
p { margin: 0.6em 0; text-indent: 2em; }
p.meta, p.summary { text-indent: 0; color: #666; }
p.figure { text-indent: 0; text-align: center; margin: 1em 0; }
p.figure img { max-width: 100%; height: auto; }
''');

    add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">wenku8-${book.id}</dc:identifier>
    <dc:title>${_escape(book.title)}</dc:title>
    <dc:creator>${_escape(book.author)}</dc:creator>
    <dc:language>zh</dc:language>
    <dc:description>${_escape(book.summary)}</dc:description>
    <dc:subject>${_escape(book.category)}</dc:subject>
    <meta name="wenku8:complete" content="${book.status.contains('完结') ? '1' : '0'}"/>
    <meta name="wenku8:updated" content="${_escape(book.updated)}"/>
    <meta name="wenku8:status" content="${_escape(book.status)}"/>
    <meta name="wenku8:id" content="${_escape(book.id)}"/>
    <meta name="wenku8:category" content="${_escape(book.category)}"/>
    <meta property="dcterms:modified">1990-01-01T00:00:00Z</meta>
${cover == null ? '' : '    <meta name="cover" content="cover-image"/>'}
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
$manifest$imageManifest  </manifest>
  <spine toc="ncx">
$spine  </spine>
</package>
''');

    add('OEBPS/toc.ncx', '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="wenku8-${book.id}"/>
    <meta name="dtb:depth" content="2"/>
  </head>
  <docTitle><text>${_escape(book.title)}</text></docTitle>
  <navMap>
$navPoints  </navMap>
</ncx>
''');

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String _xhtml(String title, String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh">
<head>
  <meta charset="utf-8"/>
  <title>${_escape(title)}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
$body
</body>
</html>
''';

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  static String _first(String html, List<RegExp> patterns) {
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null && match.groupCount >= 1) {
        final value = match.group(1);
        if (value != null && value.trim().isNotEmpty) return value;
      }
    }
    return '';
  }

  static String _field(String html, String label) {
    final match = RegExp(
      '$label[:：]\\s*(?:<[^>]+>\\s*)*([^<\\n]+)',
    ).firstMatch(html);
    final value = _clean(match?.group(1) ?? '');
    return value;
  }

  static String _clean(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n')
      .trim();

  static const _junk = {'文库', 'www.wenku8.net', 'Wenku8', '笔趣阁'};

  /// Lines that are scan credits or site notices rather than story text.
  static const _creditMarkers = [
    '轻之国度',
    '图源：',
    '图源:',
    '录入：',
    '录入:',
    '转自',
    '禁止转载',
    '首发',
    '本文来自',
    '手机用户请',
    '本章未完',
  ];

  static String _plain(String html) => _clean(html)
      .split('\n')
      .map((line) => line.trim())
      .where(
        (line) =>
            line.isNotEmpty &&
            !_junk.contains(line) &&
            !line.startsWith('请记住本书') &&
            !line.contains('wenku8') &&
            !_creditMarkers.any(line.contains),
      )
      .join('\n')
      .trim();

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

/// 站点正文里用文字代替插图，例如「（插图007）」「(插图7)」「【插图11】」。
final RegExp _illustrationPlaceholder = RegExp(
  r'^[（(【\[]\s*插\s*[图圖]\s*0*(\d{1,3})\s*[)）】\]]$',
);

/// 每个镜像域名各自的限流节奏与健康度。
///
/// 站点给每个域名一套独立配额：被限流时只有这个域名进入冷却，另一个照常
/// 可用；连不上（超时/握手失败）时累计两次就把这个域名隔离一段时间，
/// 免得继续把请求丢进会挂满一个超时的分支。
class _OriginSlot {
  _OriginSlot(this.origin);

  final String origin;

  /// 两次请求之间的最小间隔：成功就按倍率往回收，429 就翻倍。
  Duration gap = const Duration(milliseconds: 900);

  /// 下一次允许发请求的时间。
  DateTime next = DateTime.fromMillisecondsSinceEpoch(0);

  /// 冷却截止时间（429 或连续失败时设置）。
  DateTime? blockedUntil;

  /// 往返耗时指数平均（毫秒），目前只用于诊断显示。
  double ema = 0;

  int failures = 0;
  int requests = 0;
  int throttles = 0;
}
