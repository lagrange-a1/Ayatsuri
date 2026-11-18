import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/proxies/group_label.dart';

void main() {
  group('cleanGroupLabel', () {
    test('drops leading emoji but keeps the readable name', () {
      expect(cleanGroupLabel('🚀 Hong Kong 01'), 'Hong Kong 01');
      expect(cleanGroupLabel('✅ 日本 高级 专线 A'), '日本 高级 专线 A');
    });

    test('handles ZWJ families, variation selectors and keycaps', () {
      expect(cleanGroupLabel('👨‍👩‍👧‍👦 Family'), 'Family');
      expect(cleanGroupLabel('❤️ Love'), 'Love');
      expect(cleanGroupLabel('1️⃣ Best'), '1 Best');
    });

    test('collapses whitespace and truncates long marketing names', () {
      expect(cleanGroupLabel('  A   B  '), 'A B');
      final label = cleanGroupLabel('🚀 香港 01 超级精品高速专线 稳定不限速 推荐');
      expect(label.length, lessThanOrEqualTo(kGroupLabelMaxChars));
      expect(label.endsWith('…'), isTrue);
    });

    test('an emoji-only name still yields a capped, non-empty label', () {
      final label = cleanGroupLabel('🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀');
      expect(label, isNotEmpty);
      expect(label.length, lessThanOrEqualTo(kGroupLabelMaxChars));
    });

    test('plain names are untouched', () {
      expect(cleanGroupLabel('PROXY'), 'PROXY');
      expect(cleanGroupLabel('GLOBAL'), 'GLOBAL');
    });
  });
}
