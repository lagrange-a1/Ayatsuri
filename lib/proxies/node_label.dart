// Display-only cleanup for node names from the controller.
//
// Subscriptions commonly name nodes "🇭🇰 香港 | HKG 2" (flag + native name +
// code + index). The kernel needs that exact string for `PUT /proxies/<g>`,
// so it is never rewritten here — only the text in the node card and the
// selection snackbar is compacted.

import 'group_label.dart';

/// Maximum length of a compacted node label (including the ellipsis).
const int kNodeLabelMaxChars = 18;

final RegExp _whitespace = RegExp(r'\s+');
final RegExp _trailingNumber = RegExp(r'(\d+)\s*$');

String _cap(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars - 1).trimRight()}…';
}

/// Returns a short label for [raw].
///
/// Emoji are dropped. For the common "name | CODE n" shape, the human name
/// is kept and the trailing number from the code part is appended ("香港 2").
/// Names without a separator keep their text; everything is capped.
String cleanNodeLabel(String raw, {int maxChars = kNodeLabelMaxChars}) {
  if (maxChars <= 1) return '…';
  final flat = stripEmoji(raw).replaceAll(_whitespace, ' ').trim();
  if (flat.isEmpty) {
    return _cap(raw.replaceAll(_whitespace, ' ').trim(), maxChars);
  }

  final parts = flat
      .split('|')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length < 2) return _cap(flat, maxChars);

  final number = _trailingNumber.firstMatch(parts.last)?.group(1);
  final label = number == null ? parts.first : '${parts.first} $number';
  return _cap(label, maxChars);
}
