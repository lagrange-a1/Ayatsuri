import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/info/json_preview.dart';

void main() {
  group('jsonWindow', () {
    test('returns the exact prefix and never overshoots', () {
      expect(jsonWindow('abcdef', 3), 'abcdef'.substring(0, 3));
      expect(jsonWindow('abc', 10), 'abc');
      expect(jsonWindow('abc', 0), '');
      expect(jsonWindow('abc', -1), '');
    });

    test('a chunk window keeps only a bounded prefix of a large payload', () {
      final code = 'x' * 20000;
      final window = jsonWindow(code, kJsonPreviewChunk);
      expect(window.length, kJsonPreviewChunk);
      expect(code.length - window.length, 20000 - kJsonPreviewChunk);
    });
  });

  test('jsonSizeLabel stays compact', () {
    expect(jsonSizeLabel(512), '512 B');
    expect(jsonSizeLabel(2048), '2.0 KB');
    expect(jsonSizeLabel(20480), '20 KB');
  });

  test('prettyJsonInBackground yields parseable indented JSON', () async {
    final data = <String, dynamic>{
      'list': [1, 2, 3],
      'name': 'x',
    };
    final code = await prettyJsonInBackground(data);
    expect(jsonDecode(code)['list'], [1, 2, 3]);
    expect(code.contains('\n  "list"'), isTrue);
  });
}
