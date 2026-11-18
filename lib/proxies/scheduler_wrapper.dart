// lib/proxies/scheduler_wrapper.dart
import 'dart:async';
import 'package:ayatsuri/scheduler/lib.dart';

/// Scheduler wrapper for Ayatsuri proxy scheduling.
///
/// This class provides a simple interface to interact with the Rust scheduler
/// and maintain smoothed latency metrics for each proxy. When the Rust FFI
/// bridge is unavailable, it falls back to an in-memory Dart scheduler that
/// preserves EMA smoothing and lowest-latency selection.
class SchedulerWrapper {
  // Ensure the Rust library is initialized exactly once.
  static Future<void>? _initialization;
  static Scheduler? _scheduler;

  // Whether the Rust FFI bridge is usable. Flipped to false if initialization
  // fails (e.g. no linked dylib / RustLib.init was never called).
  static bool _rustAvailable = true;

  SchedulerWrapper();

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

  // EMA smoothing factor (default 0.2)
  static const double _defaultEmaAlpha = 0.2;

  final Map<String, double> _smoothedLatencies = {};
  final Map<String, BigInt> _proxyIds = {};
  int _nextId = 0;

  // Dart fallback: proxy id -> smoothed latency, used when Rust is missing.
  final Map<BigInt, BigInt> _fallbackLatencies = {};

  /// Update the latency for a proxy, maintaining EMA and adding task to scheduler.
  Future<void> updateLatency(String proxy, int latency) async {
    await _ensureRustInit();
    double smoothed;
    if (_smoothedLatencies.containsKey(proxy)) {
      final old = _smoothedLatencies[proxy]!;
      smoothed = _defaultEmaAlpha * latency + (1 - _defaultEmaAlpha) * old;
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
  /// backend is active; ties are broken by the smallest proxy id.
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

  // Optionally, reset state
  void reset() {
    _smoothedLatencies.clear();
    _proxyIds.clear();
    _nextId = 0;
    _fallbackLatencies.clear();
  }
}
