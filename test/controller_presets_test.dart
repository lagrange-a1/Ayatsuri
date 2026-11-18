import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/data/controller_presets.dart';

void main() {
  test('preset catalog is valid and detailed', () {
    expect(kControllerPresets.length, greaterThan(15));
    final ids = <String>{};
    for (final p in kControllerPresets) {
      expect(ids.add(p.id), isTrue, reason: 'duplicate preset id ${p.id}');
      expect(p.path.startsWith('/'), isTrue, reason: p.id);
      expect(
        <String>{'GET', 'PUT', 'PATCH', 'POST', 'DELETE'}.contains(p.method),
        isTrue,
        reason: p.id,
      );
      expect(p.labelZh, isNotEmpty);
      expect(p.labelEn, isNotEmpty);
      expect(p.noteZh, isNotEmpty);
      expect(p.noteEn, isNotEmpty);
    }
  });

  group('formatCurlRequest', () {
    test('renders method, path and base URL without leaking a secret', () {
      final curl = formatCurlRequest(
        baseUrl: 'http://localhost:9091/',
        method: 'patch',
        path: '/configs',
      );
      expect(curl, contains('curl -X PATCH'));
      expect(curl, contains("'http://localhost:9091/configs'"));
      expect(curl, contains('Authorization: Bearer <controller secret>'));
      expect(curl, isNot(contains('9091/secret')));
    });

    test('includes a JSON body and escapes single quotes', () {
      final curl = formatCurlRequest(
        baseUrl: 'http://h:1',
        method: 'PUT',
        path: '/proxies/GLOBAL',
        body: "{'name':'a'}",
      );
      expect(curl, contains("-H 'Content-Type: application/json'"));
      expect(curl, contains("-d '{"));
      expect(curl, contains(r"\'"));
    });
  });
}
