import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/proxies/node_label.dart';

void main() {
  group('cleanNodeLabel', () {
    test('keeps the human name and the node number', () {
      expect(cleanNodeLabel('🇭🇰 香港 | HKG 2'), '香港 2');
      expect(cleanNodeLabel('🇯🇵 日本 | JP 01'), '日本 01');
    });

    test('names without a separator keep their text', () {
      expect(cleanNodeLabel('🇺🇸 US 3'), 'US 3');
      expect(cleanNodeLabel('HKG 2'), 'HKG 2');
    });

    test('long and emoji-only names stay bounded', () {
      final long = cleanNodeLabel('🚀 超级精品高速稳定不限速专线 | LONGCODE 123456');
      expect(long.length, lessThanOrEqualTo(kNodeLabelMaxChars));
      expect(long.endsWith('…'), isTrue);
      final emojiOnly = cleanNodeLabel(
        '🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀',
      );
      expect(emojiOnly, isNotEmpty);
      expect(emojiOnly.length, lessThanOrEqualTo(kNodeLabelMaxChars));
    });
  });
}
