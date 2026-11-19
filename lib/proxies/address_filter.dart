// lib/proxies/address_filter.dart
//
// Kernel/data-layer address bypass filter.
//
// The Mihomo controller does not expose a node's `server` field to this app;
// placeholder addresses can only arrive as free-form **node names** (and as
// group `all` member names). Everything here therefore parses the name string.
// No app-settings/freezed files are touched: the enabled preset set lives on
// its own SharedPreferences key, mirroring SchedulerWrapper's backend key.

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// User-selectable address groups that should be hidden/skipped.
///
/// `private` merges the three RFC1918 blocks; `loopback` covers 127/8 plus the
/// literal token `localhost`; `cn` is loaded from a bundled CIDR list.
/// Keep the names stable — they are the persisted SharedPreferences values.
enum AddressPreset { private, loopback, cn }

/// Observable CN CIDR index load state, exposed so the settings page can show
/// a brief, non-blocking hint when the bundled list could not be loaded.
enum CnIndexState { idle, loading, ready, failed }

/// Inclusive unsigned-32-bit IPv4 range for one CIDR block.
class _CidrRange {
  const _CidrRange(this.start, this.end);

  final int start;
  final int end;

  bool contains(int ip) => ip >= start && ip <= end;
}

/// Immutable CIDR set indexed by the address's first octet.
///
/// A range that spans several first octets is registered in each bucket, so a
/// lookup only scans the (usually small) matching bucket instead of the whole
/// list. China's 7k+ entries make this worthwhile; built-in presets are tiny.
class IpCidrIndex {
  IpCidrIndex._(this._buckets);

  final Map<int, List<_CidrRange>> _buckets;

  /// Parse every `a.b.c.d/prefix` line; malformed lines are ignored.
  factory IpCidrIndex.fromCidrs(Iterable<String> cidrs) {
    final buckets = <int, List<_CidrRange>>{};
    for (final cidr in cidrs) {
      final range = _parseCidr(cidr);
      if (range == null) continue;
      final first = (range.start >> 24) & 0xFF;
      final last = (range.end >> 24) & 0xFF;
      for (var octet = first; octet <= last; octet++) {
        buckets.putIfAbsent(octet, () => <_CidrRange>[]).add(range);
      }
    }
    return IpCidrIndex._(buckets);
  }

  bool contains(int ip) {
    final bucket = _buckets[(ip >> 24) & 0xFF];
    if (bucket == null) return false;
    for (final range in bucket) {
      if (range.contains(ip)) return true;
    }
    return false;
  }

  /// Number of stored ranges (counts a multi-octet range once per bucket).
  int get length => _buckets.values.fold(0, (sum, b) => sum + b.length);
}

/// Parse a dotted-quad into an unsigned 32-bit int; `null` when invalid.
int? _parseIpv4(String text) {
  final parts = text.split('.');
  if (parts.length != 4) return null;
  var result = 0;
  for (final part in parts) {
    // Reject empty, over-long and non-decimal octets before int.tryParse.
    if (part.isEmpty || part.length > 3) return null;
    final octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) return null;
    result = (result << 8) | octet;
  }
  return result;
}

_CidrRange? _parseCidr(String line) {
  final s = line.trim();
  final slash = s.indexOf('/');
  if (slash <= 0) return null;
  final ip = _parseIpv4(s.substring(0, slash));
  if (ip == null) return null;
  final prefix = int.tryParse(s.substring(slash + 1).trim());
  if (prefix == null || prefix < 0 || prefix > 32) return null;
  if (prefix == 0) return const _CidrRange(0, 0xFFFFFFFF);
  // Masking with 0xFFFFFFFF keeps the arithmetic unsigned on the web too.
  final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  final start = ip & mask;
  final end = start | (~mask & 0xFFFFFFFF);
  return _CidrRange(start, end);
}

// Lookbehind/lookahead stop `CN 1`, version strings and 5-octet pseudo IPs
// from being read as addresses. Dart's RegExp supports lookbehind.
final RegExp _ipv4Pattern = RegExp(
  r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])',
);
final RegExp _localhostPattern = RegExp(
  r'(?<!\w)localhost(?!\w)',
  caseSensitive: false,
);

// IPv6 loopback literals: `::1` and the IPv4-mapped `::ffff:127.0.0.1`, with
// optional brackets / port. Hex/colon lookarounds stop `fe80::1` and
// `2001:db8::1` from being mistaken for loopback. Case-insensitive for `ffff`.
final RegExp _ipv6LoopbackPattern = RegExp(
  r'(?<![0-9A-Fa-f:])(?:\[::(?:1|ffff:127\.0\.0\.1)\]|::(?:1|ffff:127\.0\.0\.1))(?::\d+)?(?![0-9A-Fa-f:])',
  caseSensitive: false,
);

/// First syntactically valid IPv4 in [name], or `null`.
///
/// Accepts the common subscription forms: `SS 1.2.3.4 香港`,
/// `name | 1.2.3.4:443`, bare `127.0.0.1`, etc. Octets are range-checked.
int? extractIpv4(String name) {
  final match = _ipv4Pattern.firstMatch(name);
  if (match == null) return null;
  return _parseIpv4(match.group(0)!);
}

final IpCidrIndex _privateIndex = IpCidrIndex.fromCidrs(const <String>[
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
]);
final IpCidrIndex _loopbackIndex = IpCidrIndex.fromCidrs(const <String>[
  '127.0.0.0/8',
]);

/// Pure predicate: should a node with this name be hidden/skipped?
///
/// An empty [enabled] short-circuits to `false`, so the default behaviour is
/// byte-for-byte identical to the pre-filter app. [cnIndex] is injectable for
/// tests; production uses the cached index from [AddressFilterController].
bool shouldHideAddress(
  String name,
  Set<AddressPreset> enabled, {
  IpCidrIndex? cnIndex,
}) {
  if (enabled.isEmpty) return false;
  if (enabled.contains(AddressPreset.loopback) &&
      (_localhostPattern.hasMatch(name) ||
          _ipv6LoopbackPattern.hasMatch(name))) {
    return true;
  }
  final ip = extractIpv4(name);
  if (ip == null) return false;
  if (enabled.contains(AddressPreset.private) && _privateIndex.contains(ip)) {
    return true;
  }
  if (enabled.contains(AddressPreset.loopback) && _loopbackIndex.contains(ip)) {
    return true;
  }
  if (enabled.contains(AddressPreset.cn)) {
    final index = cnIndex ?? AddressFilterController.cnIndex;
    // No index yet / load failed => CN preset degrades to an empty set.
    if (index != null && index.contains(ip)) return true;
  }
  return false;
}

/// Storage + in-memory cache for the enabled preset set.
///
/// Deliberately independent of `AppSettings`: a corrupt preference can never
/// block boot, and the notifier updates synchronously so pages rebuild on the
/// next frame. Wire `await AddressFilterController.loadEnabled();` once before
/// `runApp` (done by the parent; not part of this file's scope).
class AddressFilterController {
  AddressFilterController._();

  /// Own SharedPreferences key, versioned like `backendPreferenceKey`.
  static const String presetsKey = 'ayatsuri_addr_filter_presets_v1';

  /// Bundled China CIDR list (raw `17mon/china_ip_list`, one CIDR per line).
  static const String cnAssetPath = 'assets/ip/china_ip_list.txt';

  /// Public listenable mirror of [enabled].
  static final ValueNotifier<Set<AddressPreset>> enabledNotifier =
      ValueNotifier<Set<AddressPreset>>(<AddressPreset>{});

  /// Currently active presets; empty by default (no filtering at all).
  static Set<AddressPreset> get enabled => enabledNotifier.value;

  static IpCidrIndex? _cnIndex;

  /// Cached CN index, or `null` when not loaded / load failed.
  static IpCidrIndex? get cnIndex => _cnIndex;

  static Future<IpCidrIndex?>? _cnFuture;

  /// Readable load state for UI surfaces (settings-page hint). Updated
  /// synchronously with the load lifecycle so listeners see failures too.
  static final ValueNotifier<CnIndexState> cnIndexStateNotifier =
      ValueNotifier<CnIndexState>(CnIndexState.idle);

  static CnIndexState get cnIndexState => cnIndexStateNotifier.value;

  /// Loader for the CN CIDR asset. Defaults to the bundled rootBundle asset;
  /// tests may override it to inject a failure and then restore it.
  static Future<String> Function(String path) cnAssetLoader = (path) =>
      rootBundle.loadString(path);

  /// Save [value] and notify listeners synchronously. Storage is best-effort.
  static Future<void> setEnabled(Set<AddressPreset> value) async {
    final next = Set<AddressPreset>.from(value);
    enabledNotifier.value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        presetsKey,
        next.map((preset) => preset.name).toList(),
      );
    } catch (e) {
      debugPrint('[AddressFilter] presets save failed: $e');
    }
    if (next.contains(AddressPreset.cn)) await loadCnIndex();
  }

  /// Restore the persisted set; unknown enum names are discarded. Missing or
  /// corrupt storage keeps the empty default so startup is never blocked.
  static Future<void> loadEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(presetsKey);
      if (raw == null) return;
      final restored = <AddressPreset>{};
      for (final name in raw) {
        for (final preset in AddressPreset.values) {
          if (preset.name == name) {
            restored.add(preset);
            break;
          }
        }
      }
      enabledNotifier.value = restored;
      if (restored.contains(AddressPreset.cn)) await loadCnIndex();
    } catch (e) {
      debugPrint('[AddressFilter] presets load failed: $e');
    }
  }

  /// Load the CN CIDR asset once and cache it. Concurrent callers share the
  /// same future; a failure is swallowed, leaves [cnIndex] `null` and clears
  /// the cached future so the next call retries instead of failing forever.
  static Future<IpCidrIndex?> loadCnIndex() {
    final pending = _cnFuture;
    if (pending != null) return pending;
    final created = _loadCnIndex();
    _cnFuture = created;
    // A failed load must not poison the cache forever. Clear it when this is
    // still the cached future and it produced no index. Doing it here (not in
    // the loader's catch) also handles a loader that throws synchronously:
    // that catch runs before `_cnFuture = created` above.
    created.then((index) {
      if (index == null && identical(_cnFuture, created)) {
        _cnFuture = null;
      }
    });
    return created;
  }

  static Future<IpCidrIndex?> _loadCnIndex() async {
    cnIndexStateNotifier.value = CnIndexState.loading;
    try {
      final text = await cnAssetLoader(cnAssetPath);
      final cidrs = text
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      final index = IpCidrIndex.fromCidrs(cidrs);
      _cnIndex = index;
      cnIndexStateNotifier.value = CnIndexState.ready;
      return index;
    } catch (e) {
      debugPrint(
        '[AddressFilter] CN CIDR asset load failed; treating CN as empty: $e',
      );
      _cnIndex = null;
      cnIndexStateNotifier.value = CnIndexState.failed;
      return null;
    }
  }

  /// Test-only reset: back to the empty default, dropping the cached asset.
  static void resetForTests() {
    enabledNotifier.value = <AddressPreset>{};
    _cnIndex = null;
    _cnFuture = null;
    cnIndexStateNotifier.value = CnIndexState.idle;
  }
}
