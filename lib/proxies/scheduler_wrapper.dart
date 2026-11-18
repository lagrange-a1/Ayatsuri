// lib/proxies/scheduler_wrapper.dart
import 'dart:async';
import 'package:ayatsuri/scheduler/lib.dart';

/// Scheduler wrapper for Ayatsuri proxy scheduling.
///
/// This class provides a simple interface to interact with the Rust scheduler
/// and maintain smoothed latency metrics for each proxy. When the Rust FFI
/// bridge is unavailable, it falls back to an in-memory Dart scheduler that
/// preserves EMA smoothing and lowest-latency selection.
///
/// The EMA smoothing factor is instance-configurable via [emaAlpha]; the
/// hysteresis used by [bestProxy] is supplied per call. All ranking helpers
/// ([ranked], [smoothedFor], [snapshot], [bestProxy]) read the Dart-side
/// mirror and never touch the destructive Rust `nextTask()` operation.
class SchedulerWrapper {
  // Ensure the Rust library is initialized exactly once.
  static Future<void>? _initialization;
  static Scheduler? _scheduler;

  // Whether the Rust FFI bridge is usable. Flipped to false if initialization
  // fails (e.g. no linked dylib / RustLib.init was never called).
  static bool _rustAvailable = true;

  /// Default EMA smoothing factor (promoted from the old private constant).
  static const double defaultEmaAlpha = 0.2;

  /// Default hysteresis (ms) for [bestProxy], matching `AppSettings`.
  static const int defaultHysteresisMs = 50;

  /// Clamp an EMA factor to the valid `[0, 1]` range.
  static double _clampAlpha(double value) {
    if (value < 0) return 0.0;
    if (value > 1) return 1.0;
    return value;
  }

  SchedulerWrapper({double emaAlpha = SchedulerWrapper.defaultEmaAlpha})
    : _emaAlpha = _clampAlpha(emaAlpha);

  double _emaAlpha;

  /// Read/write EMA factor. The setter clamps to `[0, 1]`, and
  /// [updateLatency] reads this value on every call (both backends), so
  /// changing it takes effect for subsequent samples without any reset.
  double get emaAlpha => _emaAlpha;
  set emaAlpha(double value) => _emaAlpha = _clampAlpha(value);

  final Map<String, double> _smoothedLatencies = {};
  final Map<String, BigInt> _proxyIds = {};
  int _nextId = 0;

  // Dart fallback: proxy id -> smoothed latency, used when Rust is missing.
  final Map<BigInt, BigInt> _fallbackLatencies = {};

  /// Initialize the Rust scheduler (once).
  ///
  /// Any failure is swallowed and downgrades to the Dart fallback; the shared
  /// [_initialization] future always completes normally so callers never see a
  /// broken future and updateLatency/getBestProxy never throw.
  Future<void> _ensureRustInit() async {
    if (_scheduler != null) return;
    if (_initialization != null) {
      await _initialization;
      return;
    }
    _initialization = Future.sync(() async {
      try {
        await schedulerLibInit();
        _scheduler = await Scheduler.newInstance();
        _rustAvailable = true;
      } catch (_) {
        _scheduler = null;
        _rustAvailable = false;
      }
    });
    await _initialization;
  }

  /// Update the latency for a proxy, maintaining EMA and adding task to
  /// scheduler. The configured [emaAlpha] is used by both the Rust and the
  /// Dart-fallback paths (the smoothing happens once, before the branch).
  Future<void> updateLatency(String proxy, int latency) async {
    await _ensureRustInit();
    final alpha = emaAlpha;
    double smoothed;
    if (_smoothedLatencies.containsKey(proxy)) {
      final old = _smoothedLatencies[proxy]!;
      smoothed = alpha * latency + (1 - alpha) * old;
    } else {
      smoothed = latency.toDouble();
    }
    _smoothedLatencies[proxy] = smoothed;

    if (!_proxyIds.containsKey(proxy)) {
      _proxyIds[proxy] = BigInt.from(_nextId++);
    }
    final id = _proxyIds[proxy]!;
    final taskLatency = BigInt.from(smoothed.round());

    if (_rustAvailable && _scheduler != null) {
      await _scheduler!.addTask(
        task: Task(id: id, latency: taskLatency),
      );
    } else {
      _fallbackLatencies[id] = taskLatency;
    }
  }

  /// Get the best proxy according to the scheduler.
  ///
  /// Removes and returns the name of the lowest-latency task from whichever
  /// backend is active; ties are broken by the smallest proxy id (insertion
  /// order). Kept for backwards compatibility — this is a destructive pop.
  Future<String?> getBestProxy() async {
    await _ensureRustInit();

    BigInt? bestId;
    if (_rustAvailable && _scheduler != null) {
      final task = await _scheduler!.nextTask();
      bestId = task?.id;
    } else if (_fallbackLatencies.isNotEmpty) {
      final best = _fallbackLatencies.entries.reduce((a, b) {
        final byLatency = a.value.compareTo(b.value);
        if (byLatency != 0) return byLatency < 0 ? a : b;
        return a.key.compareTo(b.key) < 0 ? a : b;
      });
      bestId = best.key;
      _fallbackLatencies.remove(best.key);
    }

    if (bestId == null) return null;
    for (final entry in _proxyIds.entries) {
      if (entry.value == bestId) return entry.key;
    }
    return null;
  }

  /// Non-destructive: all registered proxies sorted by smoothed latency
  /// ascending; ties broken by name for a stable, repeatable order.
  ///
  /// Reads only the Dart-side mirror, so it works even when Rust is
  /// unavailable and never calls the destructive `nextTask()`.
  List<MapEntry<String, double>> ranked() {
    final entries = _smoothedLatencies.entries.toList();
    entries.sort((a, b) {
      final byLatency = a.value.compareTo(b.value);
      if (byLatency != 0) return byLatency;
      return a.key.compareTo(b.key);
    });
    return entries;
  }

  /// Non-destructive lookup of a proxy's smoothed latency; `null` if unknown.
  double? smoothedFor(String proxy) => _smoothedLatencies[proxy];

  /// Remove a proxy from every mirror and, when the Rust backend is active,
  /// from the scheduler task list as well. Unknown names are a no-op.
  Future<void> remove(String proxy) async {
    final id = _proxyIds.remove(proxy);
    _smoothedLatencies.remove(proxy);
    if (id == null) return;
    _fallbackLatencies.remove(id);
    if (_rustAvailable && _scheduler != null) {
      await _scheduler!.removeTask(id: id);
    }
  }

  /// Thin convenience alias for [ranked] (compatibility with callers that
  /// expect a `snapshot()` name). Returns a fresh list each call.
  List<MapEntry<String, double>> snapshot() => ranked();

  /// Thin convenience alias for [remove].
  Future<void> removeProxy(String proxy) => remove(proxy);

  /// Non-destructive chooser with hysteresis.
  ///
  /// Picks the lowest-smoothed-latency proxy, but keeps [current] unless the
  /// best candidate is better by at least [hysteresisMs] (clamped to
  /// `[0, 5000]`, matching settings normalization). `hysteresisMs == 0`
  /// therefore means "always take the best". Blocked/timeout samples
  /// (non-positive smoothed values) never win. Uses [ranked] and
  /// [smoothedFor] only, so repeated calls are stable and nothing is popped.
  String? bestProxy({String? current, int? hysteresisMs}) {
    final hyst = (hysteresisMs ?? defaultHysteresisMs).clamp(0, 5000);
    final usable = ranked().where((e) => e.value > 0).toList();
    if (usable.isEmpty) return null;
    final top = usable.first;

    if (current == null) return top.key;
    final anchorLatency = smoothedFor(current);
    if (anchorLatency == null || anchorLatency <= 0) return top.key;
    if (top.key == current) return current;
    if (anchorLatency - top.value < hyst) return current;
    return top.key;
  }

  /// Clear all state — both this instance's mirrors and the shared static
  /// scheduler/init flags, so a subsequent call re-initializes from scratch.
  /// This also removes the cross-instance pollution caused by the statics.
  void reset() {
    _scheduler = null;
    _initialization = null;
    _rustAvailable = true;
    _fallbackLatencies.clear();
    _proxyIds.clear();
    _smoothedLatencies.clear();
    _nextId = 0;
  }
}
