import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Characters of pretty-printed JSON rendered per page.
///
/// Syntax highlighting turns each token into a `TextSpan`. On the large
/// payloads Mihomo returns (rules, connections, groups) an unbounded window
/// can build tens of thousands of spans in one frame and visibly freeze the
/// UI. Paging keeps every frame bounded; the full payload stays available
/// behind "show more".
const int kJsonPreviewChunk = 4000;

String _encode(Map<String, dynamic> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

/// Encodes on a background isolate before anything is rendered. On platforms
/// without isolates `compute` falls back to a synchronous call, but the
/// windowing below still bounds the expensive rendering step.
Future<String> prettyJsonInBackground(Map<String, dynamic> data) =>
    compute(_encode, data);

/// Prefix of [code] limited to [visibleChars]; never throws when the limit
/// is larger than the string (or negative).
String jsonWindow(String code, int visibleChars) {
  if (visibleChars <= 0) return '';
  if (visibleChars >= code.length) return code;
  return code.substring(0, visibleChars);
}

/// Compact size hint for the "show more" button.
String jsonSizeLabel(int chars) {
  if (chars < 1024) return '$chars B';
  final kb = chars / 1024;
  return kb < 10 ? '${kb.toStringAsFixed(1)} KB' : '${kb.round()} KB';
}
