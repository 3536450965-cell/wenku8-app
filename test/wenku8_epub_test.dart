import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/wenku8_source.dart';

/// Guards the two reported regressions of the online book source:
///
/// * the downloaded book must be importable at all (the library dispatches on
///   the file name extension), and
/// * the imported book must contain readable chapter text, not blank pages.
void main() {
  test('downloaded epub imports with readable chapters', () {
    final fixture = jsonDecode(
      File('test/fixtures/wenku8_book.json').readAsStringSync(),
    ) as Map<String, Object?>;

    final raw = fixture['book'] as Map<String, Object?>;
    final book = Wenku8Book(
      id: raw['id']! as String,
      title: raw['title']! as String,
      author: (raw['author'] as String?) ?? '',
      category: (raw['category'] as String?) ?? '',
      status: (raw['status'] as String?) ?? '',
      length: (raw['length'] as String?) ?? '',
      updated: (raw['updated'] as String?) ?? '',
      summary: (raw['summary'] as String?) ?? '',
    );

    final bodies = <String, String>{
      for (final entry in (fixture['bodies'] as Map<String, Object?>).entries)
        entry.key: entry.value! as String,
    };
    final volumes = <Wenku8Volume>[];
    for (final rawVolume in (fixture['volumes']! as List<Object?>)) {
      final volume = rawVolume! as Map<String, Object?>;
      final built = Wenku8Volume(volume['title']! as String);
      for (final rawChapter in (volume['chapters']! as List<Object?>)) {
        final chapter = rawChapter! as Map<String, Object?>;
        built.chapters.add(
          Wenku8Chapter(
            id: chapter['id']! as String,
            title: chapter['title']! as String,
          ),
        );
      }
      volumes.add(built);
    }

    final epub = Wenku8Client().epub(Wenku8Download(book, volumes, bodies));
    expect(epub.length, greaterThan(1024));

    final imported = parseLocalBook(LocalBookInput(book.fileName, epub));
    final chapters = imported.novel.chapters;
    expect(chapters.length, greaterThanOrEqualTo(volumes.length));
    expect(imported.bodies.length, chapters.length);

    final readable = imported.bodies.where((body) => body.trim().length > 20);
    expect(readable, isNotEmpty, reason: '导入后的正文全部为空');

    final sample = bodies.values.first;
    String squash(String value) => value.replaceAll(RegExp(r'\s+'), '');
    final joined = squash(imported.bodies.join('\n'));
    expect(joined, contains(squash(sample).substring(0, 20)));
  });

  test('illustration chapters carry their pictures into the epub', () {
    // Illustration pages on the site have no text at all; they used to abort the
    // download with "正文为空".
    final book = Wenku8Book(
      id: '999',
      title: '插图测试',
      author: '作者',
      category: '文库',
      status: '连载中',
      length: '1000字',
      updated: '2026-01-01',
      summary: '简介',
    );
    final volume = Wenku8Volume('正文')
      ..chapters.add(Wenku8Chapter(id: '1', title: '插图'));
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
      'hQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    final download = Wenku8Download(
      book,
      [volume],
      {'1': ''},
      images: {
        '1': [Wenku8Image('images/c1-0.png', Uint8List.fromList(png))],
      },
    );

    final epub = Wenku8Client().epub(download);
    final archive = ZipDecoder().decodeBytes(epub);
    expect(archive.findFile('OEBPS/images/c1-0.png'), isNotNull);
    final chapterFiles = archive.files
        .where((file) => RegExp(r'^OEBPS/chapter-\d+\.xhtml$').hasMatch(file.name))
        .map((file) => utf8.decode(file.content as List<int>))
        .toList();
    expect(chapterFiles, isNotEmpty);
    expect(
      chapterFiles.any((markup) => markup.contains('src="images/c1-0.png"')),
      isTrue,
      reason: '章节页没有引用插图',
    );
    expect(
      utf8.decode(archive.findFile('OEBPS/content.opf')!.content as List<int>),
      contains('href="images/c1-0.png"'),
    );

    final imported = parseLocalBook(LocalBookInput(book.fileName, epub));
    expect(imported.novel.chapters, isNotEmpty);
  });

  test('table of contents keeps volumes as folders', () {
    // The library decides "volume" from the NCX nesting, so a flat table of
    // contents turned every volume into one long chapter list.
    final book = Wenku8Book(
      id: '1000',
      title: '分卷测试',
      author: '作者',
      category: '文库',
      status: '连载中',
      length: '3000字',
      updated: '2026-01-01',
      summary: '简介',
    );
    Wenku8Volume volume(String title, int first, int count) {
      final built = Wenku8Volume(title);
      for (var i = 0; i < count; i++) {
        built.chapters.add(
          Wenku8Chapter(id: '${first + i}', title: '$title 第 ${i + 1} 章'),
        );
      }
      return built;
    }

    final volumes = [
      volume('第一卷', 1, 3),
      volume('第二卷', 100, 2),
    ];
    final bodies = {
      for (final v in volumes)
        for (final c in v.chapters) c.id: '正文${c.id}' * 20,
    };

    final epub = Wenku8Client().epub(Wenku8Download(book, volumes, bodies));
    final archive = ZipDecoder().decodeBytes(epub);
    final ncx = utf8.decode(
      archive.findFile('OEBPS/toc.ncx')!.content as List<int>,
    );
    expect(
      RegExp(r'<navPoint id="nav-v\d+"').allMatches(ncx).length,
      2,
      reason: '卷没有生成父级目录项',
    );

    final imported = parseLocalBook(LocalBookInput(book.fileName, epub));
    final titles = imported.novel.chapters
        .map((chapter) => chapter.volumeTitle)
        .where((title) => title.isNotEmpty)
        .toSet();
    expect(titles, containsAll(<String>['第一卷', '第二卷']));
    expect(imported.novel.chapters.length, 5);
  });

  test('cover image becomes the book cover', () {
    final book = Wenku8Book(
      id: '1001',
      title: '封面测试',
      author: '作者',
      category: '文库',
      status: '连载中',
      length: '100字',
      updated: '2026-01-01',
      summary: '简介',
    );
    final volume = Wenku8Volume('正文')
      ..chapters.add(Wenku8Chapter(id: '1', title: '第一章'));
    final jpeg = base64Decode(
      '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
      'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
      'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
    );
    final download = Wenku8Download(
      book,
      [volume],
      {'1': '正文内容' * 20},
      cover: Wenku8Image('images/cover.jpg', Uint8List.fromList(jpeg)),
    );

    final epub = Wenku8Client().epub(download);
    final archive = ZipDecoder().decodeBytes(epub);
    final opf = utf8.decode(
      archive.findFile('OEBPS/content.opf')!.content as List<int>,
    );
    expect(opf, contains('properties="cover-image"'));
    expect(opf, contains('<meta name="cover" content="cover-image"/>'));

    final imported = parseLocalBook(LocalBookInput(book.fileName, epub));
    expect(imported.novel.coverUrl, isNotEmpty);
  });
}