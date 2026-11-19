// lib/proxies/scheduler_wrapper.dart
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Uint64List;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ayatsuri/scheduler/lib.dart';

/// Which backend the scheduler actually uses for ranking decisions.
///
/// [RoutingBackend.rustFirst] is the historical default: use the native core
/// whenever it loads. [RoutingBackend.forceDart] deliberately keeps the
/// equivalent Dart twin active even when the library is present, so a user can
/// opt out of an untrusted/buggy native build without restarting the app.
enum RoutingBackend { rustFirst, forceDart }

/// Observable lifecycle of the native Rust backend.
///
/// Kept independent of [RoutingBackend] so the UI can report *why* Rust is or
/// is not in use instead of showing a permanently ambiguous badge.
enum RustBackendStatus {
  /// No load attempted yet, or a load is currently in flight.
  initializing,

  /// Library loaded and the bridge is usable.
  available,

  /// Load failed; [SchedulerWrapper.rustError] carries the readable reason.
  unavailable,
}

/// Mutable routing tunables, mirrored 1:1 into Rust's `SchedulerConfig`.
///
/// Keeping the values here (rather than reading them from Rust) lets the UI
/// render settings synchronously and gives the Dart fallback identical
/// behaviour when no native library is available.
class RoutingConfig {
  const RoutingConfig({
    this.alpha = 0.2,
    this.jitterWeight = 0.5,
    this.failurePenaltyMs = 120,
    this.stalePenaltyMs = 40,
    this.hysteresisMs = 50,
    this.cooldownMs = 10_000,
    this.maxFailures = 3,
    this.staleAfterMs = 180_000,
    this.exploreMinSamples = 3,
    this.exploreBonusMs = 8,
  });

  static const RoutingConfig defaults = RoutingConfig();

  /// NaN-safe, bounded values. The Rust core clamps the same way, so both
  /// backends must read the normalized values to stay behaviour-identical.
  double get safeAlpha => alpha.isNaN ? 0.2 : alpha.clamp(0.0, 1.0);
  double get safeHysteresis =>
      hysteresisMs.isNaN ? 50.0 : hysteresisMs.clamp(0, 5_000);

  /// Fully clamped copy; bounds mirror `SchedulerConfig` in Rust.
  static double _finite(double v, double lo, double hi) =>
      v.isFinite ? v.clamp(lo, hi) : lo;

  RoutingConfig get normalized => RoutingConfig(
    alpha: safeAlpha,
    jitterWeight: _finite(jitterWeight, 0.0, 4.0),
    failurePenaltyMs: _finite(failurePenaltyMs, 0, 10_000),
    stalePenaltyMs: _finite(stalePenaltyMs, 0, 10_000),
    hysteresisMs: safeHysteresis,
    cooldownMs: cooldownMs.clamp(0, 3_600_000),
    maxFailures: maxFailures < 1 ? 1 : maxFailures,
    staleAfterMs: staleAfterMs < 1_000 ? 1_000 : staleAfterMs,
    exploreMinSamples: exploreMinSamples < 1 ? 1 : exploreMinSamples,
    exploreBonusMs: _finite(exploreBonusMs, 0, 500),
  );

  final double alpha;
  final double jitterWeight;
  final double failurePenaltyMs;
  final double stalePenaltyMs;
  final double hysteresisMs;
  final int cooldownMs;
  final int maxFailures;
  final int staleAfterMs;
  final int exploreMinSamples;
  final double exploreBonusMs;

  SchedulerConfig get rustConfig => SchedulerConfig(
    alpha: safeAlpha,
    jitterWeight: _finite(jitterWeight, 0.0, 4.0),
    failurePenaltyMs: _finite(failurePenaltyMs, 0, 10_000),
    stalePenaltyMs: _finite(stalePenaltyMs, 0, 10_000),
    hysteresisMs: safeHysteresis,
    cooldownMs: BigInt.from(cooldownMs.clamp(0, 3_600_000)),
    maxFailures: maxFailures < 1 ? 1 : maxFailures,
    staleAfterMs: BigInt.from(staleAfterMs < 1_000 ? 1_000 : staleAfterMs),
    exploreMinSamples: exploreMinSamples < 1 ? 1 : exploreMinSamples,
    exploreBonusMs: _finite(exploreBonusMs, 0, 500),
  );

  RoutingConfig copyWith({
    double? alpha,
    double? jitterWeight,
    double? failurePenaltyMs,
    double? stalePenaltyMs,
    double? hysteresisMs,
    int? cooldownMs,
    int? maxFailures,
    int? staleAfterMs,
    int? exploreMinSamples,
    double? exploreBonusMs,
  }) => RoutingConfig(
    alpha: alpha ?? this.alpha,
    jitterWeight: jitterWeight ?? this.jitterWeight,
    failurePenaltyMs: failurePenaltyMs ?? this.failurePenaltyMs,
    stalePenaltyMs: stalePenaltyMs ?? this.stalePenaltyMs,
    hysteresisMs: hysteresisMs ?? this.hysteresisMs,
    cooldownMs: cooldownMs ?? this.cooldownMs,
    maxFailures: maxFailures ?? this.maxFailures,
    staleAfterMs: staleAfterMs ?? this.staleAfterMs,
    exploreMinSamples: exploreMinSamples ?? this.exploreMinSamples,
    exploreBonusMs: exploreBonusMs ?? this.exploreBonusMs,
  );
}

/// Non-destructive ranking result for a single proxy.
class NodeRank {
  const NodeRank({
    required this.proxy,
    required this.ewma,
    required this.jitter,
    required this.score,
    required this.samples,
    required this.failures,
    required this.ageMs,
    required this.available,
  });

  final String proxy;
  final double ewma;
  final double jitter;
  final double score;
  final int samples;
  final int failures;
  final int ageMs;
  final bool available;

  /// True while a node has too few samples for a confident ranking.
  bool get lowConfidence => samples < 3;

  @override
  String toString() =>
      'NodeRank($proxy: ewma=${ewma.toStringAsFixed(1)}, '
      'jitter=${jitter.toStringAsFixed(1)}, score=${score.toStringAsFixed(1)}, '
      'samples=$samples, failures=$failures)';
}

class _DartNode {
  _DartNode(this.ewma)
    : jitter = 0,
      samples = 0,
      failures = 0,
      lastSeenMs = 0,
      available = true;

  double ewma;
  double jitter;
  int samples;
  int failures;
  int lastSeenMs;
  bool available;
}

/// Bridge between the app's proxy names and the native Rust scheduler.
///
/// The native core is used whenever it can be constructed; otherwise an
/// in-Dart implementation of the same scoring rules keeps the app functional
/// (tests, web, devices without a packaged dylib).
class SchedulerWrapper {
  SchedulerWrapper({RoutingConfig? config})
    : _config = (config ?? RoutingConfig.defaults).normalized;

  static LatencyScheduler? _rust;
  static bool _rustTried = false;

  /// Shared in-flight init. The first caller creates it synchronously; every
  /// concurrent caller awaits the same future, so no probe result is recorded
  /// only to the Dart mirror while Rust is still loading.
  static Future<void>? _rustInitFuture;

  static RustBackendStatus _rustStatus = RustBackendStatus.initializing;
  static String? _rustError;
  static RoutingBackend _backendPreference = RoutingBackend.rustFirst;

  /// Storage key for the persisted routing preference. Kept on its own key
  /// (outside the big AppSettings JSON document) so this fix never has to
  /// touch the freezed/json_serializable generated files.
  static const String backendPreferenceKey = 'ayatsuri_scheduler_backend_v1';

  /// Public listenable mirror of [backendPreference].
  ///
  /// The scheduler chip binds to this: switching the preference on the
  /// settings page notifies it synchronously, so the chip rebuilds on the
  /// very next frame even when it lives on a different page.
  static final ValueNotifier<RoutingBackend> backendPreferenceNotifier =
      ValueNotifier<RoutingBackend>(RoutingBackend.rustFirst);

  RoutingConfig _config;

  /// Rust instance actually used for *reads*, honouring the user preference.
  /// Writes always feed [_rust] too, so switching back to Rust never needs a
  /// reload and never loses samples recorded while Dart was forced.
  LatencyScheduler? get _effectiveRust =>
      _backendPreference == RoutingBackend.forceDart ? null : _rust;

  /// True when the native Rust core is the active ranking backend.
  /// Kept as an overridable instance getter so test fakes keep working.
  bool get rustActive => _effectiveRust != null;

  /// True when a native library was looked up (successfully or not).
  static bool get rustAttempted => _rustTried;

  /// Lifecycle of the native library, independent of the user preference.
  static RustBackendStatus get rustStatus => _rustStatus;

  /// Human-readable reason the native library is unavailable, if any.
  static String? get rustError => _rustError;

  /// Currently selected backend preference.
  static RoutingBackend get backendPreference => _backendPreference;

  /// Switch backend at runtime. Both backends stay fed with every sample, so
  /// this takes effect on the very next rank/best call without a reload.
  ///
  /// The notifier is updated **synchronously** (before the first await) so a
  /// listening UI rebuilds immediately; the write to SharedPreferences is
  /// asynchronous and best-effort — a storage failure must never break the
  /// running app.
  static Future<void> setBackendPreference(RoutingBackend preference) async {
    _backendPreference = preference;
    backendPreferenceNotifier.value = preference;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(backendPreferenceKey, preference.name);
    } catch (e) {
      debugPrint('[SchedulerWrapper] backend preference save failed: $e');
    }
  }

  /// Restore the preference written by [setBackendPreference]. Awaited once
  /// during startup; a missing, corrupt or unknown value keeps the default
  /// `rustFirst` so a bad preference can never block app boot.
  static Future<void> loadBackendPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(backendPreferenceKey);
      if (raw == null) return;
      for (final candidate in RoutingBackend.values) {
        if (candidate.name == raw) {
          _backendPreference = candidate;
          backendPreferenceNotifier.value = candidate;
          return;
        }
      }
    } catch (e) {
      debugPrint('[SchedulerWrapper] backend preference load failed: $e');
    }
  }

  static const double defaultEmaAlpha = 0.2;
  static const int defaultHysteresisMs = 50;

  final Map<String, int> _ids = <String, int>{};
  final Map<int, String> _names = <int, String>{};
  final Map<int, _DartNode> _mirror = <int, _DartNode>{};
  int _nextId = 0;
  int? _lastSwitchMs;
  int? _lastSwitchTo;

  double get emaAlpha => _config.alpha;
  set emaAlpha(double value) => configure(_config.copyWith(alpha: value));

  RoutingConfig get config => _config;

  Future<void> _ensureRust() async {
    final pending = _rustInitFuture;
    if (pending != null) {
      // Another caller is already loading the library; wait for it so this
      // observation reaches the same backend rather than racing ahead.
      await pending;
      return;
    }
    if (_rustTried) return;
    _rustTried = true;
    _rustInitFuture = _loadRust();
    await _rustInitFuture;
  }

  Future<void> _loadRust() async {
    try {
      _rust = await LatencyScheduler.newInstance(config: _config.rustConfig);
      _rustStatus = RustBackendStatus.available;
      _rustError = null;
    } catch (e) {
      // No linked dylib / RustLib.init() never ran / web build without wasm.
      // Record a readable reason instead of silently swallowing it: the
      // settings page surfaces this so users are never left guessing.
      _rust = null;
      _rustStatus = RustBackendStatus.unavailable;
      _rustError = e.toString();
      debugPrint('[SchedulerWrapper] Rust backend unavailable: $e');
    }
  }

  int _idFor(String proxy) {
    final existing = _ids[proxy];
    if (existing != null) return existing;
    final id = _nextId++;
    _ids[proxy] = id;
    _names[id] = proxy;
    return id;
  }

  String? _nameFor(int id) => _names[id];

  /// Record a probe result: any positive delay is a sample, `0` means blocked
  /// and negative (the `-1` timeout sentinel) counts as a timeout failure.
  Future<void> record(String proxy, int delay) async {
    if (delay > 0) {
      await observe(proxy, delay);
    } else {
      await fail(proxy, timeout: delay < 0);
    }
  }

  Future<void> observe(String proxy, int latencyMs) async {
    await _ensureRust();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _idFor(proxy);
    _mirrorObserve(id, latencyMs, now);
    final rust = _rust;
    if (rust != null) {
      await rust.observe(
        id: BigInt.from(id),
        latencyMs: BigInt.from(latencyMs),
        nowMs: BigInt.from(now),
      );
    }
  }

  Future<void> fail(String proxy, {bool timeout = false}) async {
    await _ensureRust();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _idFor(proxy);
    _mirrorFail(id, timeout: timeout, now: now);
    final rust = _rust;
    if (rust != null) {
      await rust.fail(
        id: BigInt.from(id),
        timeout: timeout,
        nowMs: BigInt.from(now),
      );
    }
  }

  int? proxyId(String proxy) => _ids[proxy];

  Iterable<String> get knownProxies => _ids.keys;

  /// All available candidates sorted by score ascending, non-destructive.
  Future<List<NodeRank>> rank(Iterable<String> candidates) async {
    await _ensureRust();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = candidates.map(proxyId).whereType<int>().toList();
    final rust = _effectiveRust;
    if (rust != null) {
      final rows = await rust.rank(
        candidates: Uint64List.fromList(ids),
        nowMs: BigInt.from(now),
      );
      // Rust owns the arithmetic, so surface Rust's numbers directly rather
      // than recomputing them in the Dart mirror.
      return rows
          .map((r) {
            final name = _nameFor(r.id.toInt());
            if (name == null) return null;
            return NodeRank(
              proxy: name,
              ewma: r.ewma,
              jitter: r.jitter,
              score: r.score,
              samples: r.samples,
              failures: r.failures,
              ageMs: r.ageMs.toInt(),
              available: r.available,
            );
          })
          .whereType<NodeRank>()
          .toList();
    }
    return _rankLocal(ids, now);
  }

  /// Choose the best candidate. `current` is kept unless the improvement is
  /// larger than hysteresis and the switch cooldown has elapsed.
  Future<String?> best(Iterable<String> candidates, {String? current}) async {
    await _ensureRust();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = candidates.map(proxyId).whereType<int>().toList();
    final currentId = current == null ? null : _ids[current];
    final rust = _effectiveRust;
    if (rust != null) {
      final picked = await rust.best(
        candidates: Uint64List.fromList(ids),
        current: currentId == null ? null : BigInt.from(currentId),
        nowMs: BigInt.from(now),
      );
      return picked == null ? null : _nameFor(picked.id.toInt());
    }
    final local = _bestLocal(ids, currentId, now);
    return local == null ? null : _nameFor(local);
  }

  /// Synchronous read of a node's mirrored stats (works without awaiting FFI).
  NodeRank? statsFor(String proxy) {
    if (!_ids.containsKey(proxy)) return null;
    return mirrorRank(proxy, DateTime.now().millisecondsSinceEpoch);
  }

  /// Legacy non-destructive snapshot: proxies sorted by smoothed latency.
  List<MapEntry<String, double>> ranked() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows =
        _ids.entries
            .where((e) => _mirror[e.value]?.available == true)
            .map((e) => MapEntry(e.key, _score(_mirror[e.value], now)))
            .where((e) => e.value.isFinite)
            .toList()
          ..sort((a, b) {
            final cmp = a.value.compareTo(b.value);
            return cmp != 0 ? cmp : a.key.compareTo(b.key);
          });
    return rows;
  }

  List<MapEntry<String, double>> snapshot() => ranked();

  double? smoothedFor(String proxy) {
    final id = _ids[proxy];
    final node = id == null ? null : _mirror[id];
    return node?.ewma;
  }

  /// Compatibility alias: choosing without a destructive pop.
  Future<String?> getBestProxy() => best(_ids.keys);

  Future<void> remove(String proxy) async {
    final id = _ids.remove(proxy);
    if (id == null) return;
    _names.remove(id);
    _mirror.remove(id);
    if (_lastSwitchTo == id) {
      _lastSwitchTo = null;
      _lastSwitchMs = null;
    }
    final rust = _rust;
    if (rust != null) await rust.remove(id: BigInt.from(id));
  }

  Future<void> removeProxy(String proxy) => remove(proxy);

  void configure(RoutingConfig config) {
    _config = config.normalized;
    final rust = _rust;
    if (rust != null) {
      // Fire-and-forget: the only effect is replacing a config object.
      rust.configure(config: config.rustConfig);
    }
  }

  Future<void> updateLatency(String proxy, int latency) =>
      observe(proxy, latency);

  void reset() {
    _ids.clear();
    _names.clear();
    _mirror.clear();
    _nextId = 0;
    _lastSwitchMs = null;
    _lastSwitchTo = null;
    _rust?.clear();
  }

  static void resetForTests() {
    _rust?.clear();
    _rust = null;
    _rustTried = false;
    _rustInitFuture = null;
    _rustStatus = RustBackendStatus.initializing;
    _rustError = null;
    _backendPreference = RoutingBackend.rustFirst;
    backendPreferenceNotifier.value = RoutingBackend.rustFirst;
  }

  // ------------------------------------------------------------------------
  // Dart fallback: same formulas as rust/scheduler/src/lib.rs
  // ------------------------------------------------------------------------

  void _mirrorObserve(int id, int latencyMs, int now) {
    final node = _mirror.putIfAbsent(id, () => _DartNode(latencyMs.toDouble()));
    if (node.samples == 0) {
      node.ewma = latencyMs.toDouble();
      node.jitter = 0;
    } else {
      final deviation = (latencyMs - node.ewma).abs();
      final a = _config.alpha;
      node.ewma = a * latencyMs + (1 - a) * node.ewma;
      node.jitter = a * deviation + (1 - a) * node.jitter;
    }
    node.samples++;
    if (node.failures > 0) node.failures--;
    node.available = true;
    node.lastSeenMs = now;
  }

  void _mirrorFail(int id, {required bool timeout, required int now}) {
    final node = _mirror.putIfAbsent(id, () => _DartNode(double.maxFinite));
    // Match Rust's fail(): a node created by a failed probe still gets a
    // timestamp so its reported age is 0, not "since epoch".
    if (node.samples == 0 && node.failures == 0) node.lastSeenMs = now;
    node.failures += timeout ? 2 : 1;
    if (node.failures >= _config.maxFailures) node.available = false;
  }

  double _score(_DartNode? node, int now) {
    if (node == null || node.samples == 0) return double.maxFinite;
    final age = now - node.lastSeenMs;
    final staleUnits = age > _config.staleAfterMs
        ? ((age - _config.staleAfterMs) / _config.staleAfterMs).floor() + 1
        : 0;
    final explore = node.samples < _config.exploreMinSamples
        ? (_config.exploreMinSamples - node.samples) * _config.exploreBonusMs
        : 0.0;
    final raw =
        node.ewma +
        _config.jitterWeight * node.jitter +
        node.failures * _config.failurePenaltyMs +
        staleUnits * _config.stalePenaltyMs -
        explore;
    return raw < 0 ? 0.0 : raw;
  }

  NodeRank mirrorRank(String proxy, int now) {
    final node = _mirror[_ids[proxy]];
    return NodeRank(
      proxy: proxy,
      ewma: node?.ewma ?? 0,
      jitter: node?.jitter ?? 0,
      score: _score(node, now),
      samples: node?.samples ?? 0,
      failures: node?.failures ?? 0,
      ageMs: node == null ? 0 : now - node.lastSeenMs,
      available: node?.available ?? false,
    );
  }

  List<NodeRank> _rankLocal(List<int> ids, int now) {
    final rows =
        ids
            .where((id) => _mirror[id]?.available == true)
            .map((id) => mirrorRank(_names[id]!, now))
            .toList()
          ..sort((a, b) {
            final cmp = a.score.compareTo(b.score);
            return cmp != 0 ? cmp : a.proxy.compareTo(b.proxy);
          });
    return rows;
  }

  int? _bestLocal(List<int> ids, int? current, int now) {
    final ranked = _rankLocal(ids, now);
    if (ranked.isEmpty) return null;
    final top = ranked.first;
    if (current != null) {
      NodeRank? held;
      for (final row in ranked) {
        if (_ids[row.proxy] == current) {
          held = row;
          break;
        }
      }
      if (held != null) {
        final cooling =
            _lastSwitchMs != null && now - _lastSwitchMs! < _config.cooldownMs;
        if (cooling || held.score - top.score <= _config.hysteresisMs) {
          return current;
        }
      }
    }
    _lastSwitchMs = now;
    _lastSwitchTo = _ids[top.proxy];
    return _ids[top.proxy];
  }
}
