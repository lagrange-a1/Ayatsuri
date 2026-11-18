// Display-only cleanup for proxy-group names coming from the controller.
//
// Many subscription configs name groups with a string of emoji and long
// marketing suffixes ("🚀 香港 01 · 精品高速专线…"). The kernel needs those
// exact names for `PUT /proxies/<group>`, so they are never rewritten here —
// only the label shown in the picker and the Info dashboard is compacted.

/// Maximum length of a compacted label (including the ellipsis).
const int kGroupLabelMaxChars = 16;

/// True for emoji, dingbats, arrows, skin tones and their joiner/modifier
/// characters. Done on runes so astral-plane emoji work without regex
/// escape quirks on any Dart backend.
bool _isDecoration(int r) =>
    (r >= 0x1F000 && r <= 0x1FAFF) ||
    (r >= 0x2600 && r <= 0x27BF) ||
    (r >= 0x2B00 && r <= 0x2BFF) ||
    (r >= 0x2190 && r <= 0x21FF) ||
    (r >= 0x1F3FB && r <= 0x1F3FF) ||
    r == 0xFE0F || // variation selector
    r == 0x200D || // zero-width joiner
    r == 0x20E3; // combining keycap

/// Removes emoji and their joiner/modifier characters, replacing each with
/// a space. Exposed so node and group labels share one normalization rule.
String stripEmoji(String raw) {
  final buffer = StringBuffer();
  for (final r in raw.runes) {
    if (_isDecoration(r)) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(r);
    }
  }
  return buffer.toString();
}

final RegExp _runs = RegExp(r'\s+');

/// Returns a short, human-readable label for [raw].
///
/// Emoji are dropped, whitespace is collapsed, and overly long names are
/// truncated with an ellipsis. A name made entirely of emoji falls back to
/// the raw text so the group stays distinguishable; it is capped too.
String cleanGroupLabel(String raw, {int maxChars = kGroupLabelMaxChars}) {
  if (maxChars <= 1) return '…';
  final flat = stripEmoji(raw).replaceAll(_runs, ' ').trim();
  final source = flat.isEmpty ? raw.replaceAll(_runs, ' ').trim() : flat;
  if (source.length <= maxChars) return source;
  return '${source.substring(0, maxChars - 1).trimRight()}…';
}
