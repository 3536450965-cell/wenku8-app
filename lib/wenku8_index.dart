import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart' show gbk;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// One row of the bundled/remote Wenku8 title index.
class Wenku8IndexEntry {
  const Wenku8IndexEntry({
    required this.id,
    required this.title,
    this.author = '',
    this.category = '',
    this.status = '',
    this.length = 0,
  });

  final int id;
  final String title;
  final String author;
  final String category;
  final String status;
  final int length;

  String get lengthLabel =>
      length >= 10000 ? '${(length / 10000).toStringAsFixed(1)} 万字' : '$length 字';

  static Wenku8IndexEntry? fromRow(dynamic row) {
    if (row is! List || row.length < 2) return null;
    final id = row[0];
    final title = row[1];
    if (id is! int || title is! String || title.isEmpty) return null;
    String text(int index) {
      if (row.length <= index) return '';
      final value = row[index];
      return value is String ? value : '';
    }

    final rawLength = row.length > 5 ? row[5] : 0;
    return Wenku8IndexEntry(
      id: id,
      title: title,
      author: text(2),
      category: text(3),
      status: text(4),
      length: rawLength is int ? rawLength : 0,
    );
  }
}

/// Title -> book id lookup table for the online source.
///
/// The site's own search needs an account that can no longer be created, so the
/// app ships a compact index of every book whose page we could read and filters
/// it locally. A newer copy is fetched opportunistically and cached on disk, so
/// the table can grow without shipping a new build.
class Wenku8Index {
  Wenku8Index(this.entries, {this.updated = false});

  final List<Wenku8IndexEntry> entries;

  /// True when [entries] came from the network during this session.
  final bool updated;

  static const assetKey = 'assets/wenku8_index.json';

  static const remoteUrls = [
    'https://cdn.jsdelivr.net/gh/3536450965-cell/Wenku8_Flutter@master/data/wenku8_index.json',
    'https://raw.githubusercontent.com/3536450965-cell/Wenku8_Flutter/master/data/wenku8_index.json',
  ];

  /// A weekly job in the repository appends newly published books, so a short
  /// window keeps search fresh without re-downloading the table on every launch.
  static const _maxAge = Duration(days: 2);
  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

  static Future<File> cacheFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/wenku8_index.json');
  }

  /// Loads the table, preferring a fresh disk cache, then the network, and
  /// finally the copy bundled with the app (which works offline).
  /// Drops the cached copy, fetches the newest index, then falls back to the
  /// bundled asset so the search box never ends up empty.
  static Future<Wenku8Index> forceRefresh() async {
    try {
      final cache = await cacheFile();
      if (await cache.exists()) await cache.delete();
    } catch (_) {}
    return load();
  }

  static Future<Wenku8Index> load() async {
    final cache = await cacheFile();
    if (await cache.exists()) {
      final age = DateTime.now().difference((await cache.stat()).modified);
      if (age < _maxAge) {
        final cached = await _readFile(cache);
        if (cached != null && cached.entries.isNotEmpty) return cached.index;
      }
    }
    final remote = await _fetchRemote();
    if (remote != null && remote.entries.isNotEmpty) {
      try {
        await cache.writeAsString(remote.raw, flush: true);
      } catch (_) {
        // A failing cache write must not lose the freshly downloaded table.
      }
      return remote.index;
    }
    if (await cache.exists()) {
      final cached = await _readFile(cache);
      if (cached != null && cached.entries.isNotEmpty) return cached.index;
    }
    final bundled = await _readAsset();
    if (bundled != null && bundled.entries.isNotEmpty) return bundled.index;
    throw const Wenku8IndexUnavailable();
  }

  /// Highest id in the table; new books take the next free id, so the in-app
  /// probe starts here.
  int get maxId {
    var highest = 0;
    for (final entry in entries) {
      if (entry.id > highest) highest = entry.id;
    }
    return highest;
  }

  /// Merges freshly probed rows into the on-disk cache so they survive a
  /// restart, and returns the merged table.
  ///
  /// The site answers new titles to the phone but blocks GitHub's runners, so
  /// the device reports what it found instead of waiting for the weekly job.
  Future<Wenku8Index> withEntries(Iterable<Wenku8IndexEntry> extra) async {
    final byId = <int, Wenku8IndexEntry>{for (final entry in entries) entry.id: entry};
    for (final entry in extra) {
      byId[entry.id] = entry;
    }
    final merged = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    final raw = jsonEncode([
      for (final entry in merged)
        [entry.id, entry.title, entry.author, entry.category, entry.status, entry.length],
    ]);
    try {
      final cache = await cacheFile();
      await cache.writeAsString(raw, flush: true);
    } catch (_) {
      // A read-only cache still lets the session use the merged table.
    }
    return Wenku8Index(merged, updated: true);
  }

  static Future<_Loaded?> _readFile(File file) async {
    try {
      return _Loaded.decode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<_Loaded?> _readAsset() async {
    try {
      return _Loaded.decode(await rootBundle.loadString(assetKey));
    } catch (_) {
      return null;
    }
  }

  static Future<_Loaded?> _fetchRemote() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      for (final url in remoteUrls) {
        try {
          final request = await client.getUrl(Uri.parse(url));
          request.headers.set(HttpHeaders.userAgentHeader, _ua);
          final response = await request.close().timeout(const Duration(seconds: 25));
          if (response.statusCode != 200) {
            await response.drain<void>();
            continue;
          }
          final raw = await response.transform(utf8.decoder).join();
          final loaded = _Loaded.decode(raw);
          if (loaded != null && loaded.entries.isNotEmpty) {
            return _Loaded(raw: raw, index: Wenku8Index(loaded.entries, updated: true));
          }
        } catch (_) {
          // Try the next mirror.
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Fuzzy title/author search.
  ///
  /// Matches, in priority order: a plain substring of the title or author, the
  /// pinyin initials of the title (`bdnj` -> 败北女角太多了), and an in-order
  /// abbreviation of those initials. The index is a plain list of 4000+ books,
  /// so a linear pass stays well under a frame.
  List<Wenku8IndexEntry> search(String query, {int limit = 80}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final ascii = RegExp(r'^[a-z]+$').hasMatch(needle);
    final hits = <(int, int, Wenku8IndexEntry)>[];
    for (final entry in entries) {
      final title = entry.title.toLowerCase();
      final author = entry.author.toLowerCase();
      var score = -1;
      if (title.startsWith(needle)) {
        score = 0;
      } else if (title.contains(needle) || author.contains(needle)) {
        score = 1;
      } else if (ascii) {
        final initials = _initialsOf(entry);
        if (initials.startsWith(needle)) {
          score = 2;
        } else if (initials.length >= needle.length &&
            _editDistanceAtMostOne(needle, initials.substring(0, needle.length))) {
          // One wrong initial in the prefix: bdnj for bbnj.
          score = 2;
        } else if (needle.length >= 3 && _fuzzyContains(needle, initials)) {
          // Forgive one wrong initial, e.g. bdnj for bbnj. This ranks above a
          // loose subsequence hit, which tends to be an unrelated title.
          score = 3;
        } else if (_subsequence(needle, initials)) {
          score = 4;
        }
      }
      if (score < 0 && needle.length >= 2) {
        // One wrong/extra/missing character still counts, so a typo such as
        // 败北女角真多了 still finds the book.
        if (_fuzzyContains(needle, title)) {
          score = 5;
        } else if (author.isNotEmpty && _fuzzyContains(needle, author)) {
          score = 6;
        }
      }
      if (score >= 0) hits.add((score, entry.title.length, entry));
    }
    hits.sort((a, b) {
      final byScore = a.$1 - b.$1;
      if (byScore != 0) return byScore;
      final byLength = a.$2 - b.$2;
      if (byLength != 0) return byLength;
      return a.$3.id.compareTo(b.$3.id);
    });
    return [
      for (final hit in hits.take(limit)) hit.$3,
    ];
  }

  final Map<int, String> _initialsCache = <int, String>{};

  String _initialsOf(Wenku8IndexEntry entry) =>
      _initialsCache[entry.id] ??= pinyinInitials(entry.title);

  /// True when [needle] occurs in [haystack] with at most one edit, which is
  /// enough to forgive a typo without pulling in unrelated titles.
  static bool _fuzzyContains(String needle, String haystack) {
    final n = needle.length;
    if (n < 2 || haystack.length + 1 < n) return false;
    for (var start = 0; start <= haystack.length - n + 1; start++) {
      for (final window in [n - 1, n, n + 1]) {
        if (window <= 0) continue;
        final end = start + window;
        if (end > haystack.length) continue;
        if (_editDistanceAtMostOne(needle, haystack.substring(start, end))) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _editDistanceAtMostOne(String a, String b) {
    if (a == b) return true;
    final delta = a.length - b.length;
    if (delta > 1 || delta < -1) return false;
    var i = 0;
    var j = 0;
    var edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (delta == 0) {
        i++;
        j++;
      } else if (delta > 0) {
        i++;
      } else {
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }

  static bool _subsequence(String needle, String haystack) {
    var index = 0;
    for (var i = 0; i < haystack.length && index < needle.length; i++) {
      if (haystack[i] == needle[index]) index++;
    }
    return index == needle.length;
  }
}

/// First letter of every Han character in [text], using the GB2312 code ranges
/// that the classic sort tables are built on. Non-Han characters are kept as
/// lowercased ASCII so "Re:零" still matches "re0"-style queries.
String pinyinInitials(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (rune < 0x80) {
      final lower = char.toLowerCase();
      if (lower.trim().isEmpty) continue;
      if (RegExp(r'[a-z0-9]').hasMatch(lower)) buffer.write(lower);
      continue;
    }
    if (rune >= 0x4e00 && rune <= 0x9fff) {
      buffer.write(_initialOf(rune));
    }
  }
  return buffer.toString();
}

String _initialOf(int rune) {
  final bytes = gbk.encode(String.fromCharCode(rune));
  if (bytes.length < 2) return '';
  final code = (bytes[0] << 8) | bytes[1];
  for (final row in _initialRanges) {
    if (code >= row.$1 && code <= row.$2) return row.$3;
  }
  return '';
}

const List<(int, int, String)> _initialRanges = [
  (0xB0A1, 0xB0C4, 'a'),
  (0xB0C5, 0xB2C0, 'b'),
  (0xB2C1, 0xB4ED, 'c'),
  (0xB4EE, 0xB6E9, 'd'),
  (0xB6EA, 0xB7A1, 'e'),
  (0xB7A2, 0xB8C0, 'f'),
  (0xB8C1, 0xB9FD, 'g'),
  (0xB9FE, 0xBBF6, 'h'),
  (0xBBF7, 0xBFA5, 'j'),
  (0xBFA6, 0xC0AB, 'k'),
  (0xC0AC, 0xC2E7, 'l'),
  (0xC2E8, 0xC4C2, 'm'),
  (0xC4C3, 0xC5B5, 'n'),
  (0xC5B6, 0xC5BD, 'o'),
  (0xC5BE, 0xC6D9, 'p'),
  (0xC6DA, 0xC8BA, 'q'),
  (0xC8BB, 0xC8F5, 'r'),
  (0xC8F6, 0xCBF9, 's'),
  (0xCBFA, 0xCDD9, 't'),
  (0xCDDA, 0xCEF3, 'w'),
  (0xCEF4, 0xD1B8, 'x'),
  (0xD1B9, 0xD4D0, 'y'),
  (0xD4D1, 0xD7F9, 'z'),
];
class Wenku8IndexUnavailable implements Exception {
  const Wenku8IndexUnavailable();

  @override
  String toString() => '书名索引加载失败，请检查网络后重试，或直接粘贴书籍链接。';
}

class _Loaded {
  const _Loaded({required this.raw, required this.index});

  final String raw;
  final Wenku8Index index;

  List<Wenku8IndexEntry> get entries => index.entries;

  static _Loaded? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final entries = <Wenku8IndexEntry>[];
      for (final row in decoded) {
        final entry = Wenku8IndexEntry.fromRow(row);
        if (entry != null) entries.add(entry);
      }
      if (entries.isEmpty) return null;
      return _Loaded(raw: raw, index: Wenku8Index(entries));
    } catch (_) {
      return null;
    }
  }
}