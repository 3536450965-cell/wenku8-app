import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/wenku8_index.dart';

/// Search behaviour against the real 4420-book index that ships in the app.
void main() {
  final file = File('assets/wenku8_index.json');
  if (!file.existsSync()) {
    fail('assets/wenku8_index.json is missing');
  }
  final rows = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  final index = Wenku8Index([
    for (final row in rows) Wenku8IndexEntry.fromRow(row)!,
  ]);

  String first(String query) {
    final hits = index.search(query, limit: 5);
    if (hits.isEmpty) return '';
    return hits.first.title;
  }

  test('exact and prefix queries still work', () {
    expect(first('败北女角太多了'), contains('败北女角太多了'));
    expect(first('败北'), contains('败北'));
    expect(first('宝可梦'), isNotEmpty);
  });

  test('pinyin initials still work', () {
    expect(first('bbnjtdl'), contains('败北女角太多了'));
    // A single wrong initial still surfaces the book somewhere in the list.
    expect(
      index.search('bdnj').map((hit) => hit.title).join('|'),
      contains('败北女角太多了'),
    );
  });

  test('a single typo still finds the book', () {
    // One wrong character, one missing character, one extra character.
    for (final typo in ['败北女角太乡了', '败北女角太了', '败北女角太多多了']) {
      expect(first(typo), contains('败北女角太多了'), reason: 'typo $typo');
    }
  });

  test('nonsense does not match everything', () {
    expect(index.search('齉齉齉齉').length, 0);
  });
}