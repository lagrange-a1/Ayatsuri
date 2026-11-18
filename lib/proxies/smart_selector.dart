/*
 * SmartSelector — combines probe observation (ProbeHistory) with latency
 * ranking (SchedulerWrapper) into one pure-Dart, testable decision surface.
 *
 * Contract source: omh-pdoc/feat-observability-plan.md section 2.
 * It intentionally has no Flutter / dio / proxy_service dependency.
 */

import 'dart:async';

import 'probe_history.dart';
import 'scheduler_wrapper.dart';

/// Immutable view of a [SmartSelector]'s configuration and derived state.
class SmartSelectorSnapshot {
  const SmartSelectorSnapshot({
    required this.emaAlpha,
    required this.hysteresisMs,
    required this.current,
    required this.ema,
    required this.stats,
  });

  final double emaAlpha;
  final int hysteresisMs;
  final String? current;

  /// Smoothed latencies by proxy, ascending (from `scheduler.ranked()`).
  final Map<String, double> ema;

  /// Window statistics for every proxy with samples (from `history`).
  final Map<String, ProbeStats> stats;
}

/// Combines per-proxy probe statistics with non-destructive latency ranking.
///
/// The only write entry point is [record]. [best] is a pure suggestion and
/// never selects a node — committing is the caller's job via [adopt].
class SmartSelector {
  SmartSelector({
    ProbeHistory? history,
    SchedulerWrapper? scheduler,
    double emaAlpha = _kDefaultEmaAlpha,
    int hysteresisMs = _kDefaultHysteresisMs,
    this.current,
  }) : history = history ?? ProbeHistory(),
       scheduler =
           scheduler ?? SchedulerWrapper(emaAlpha: _clampAlpha(emaAlpha)),
       _emaAlpha = _clampAlpha(emaAlpha),
       _hysteresisMs = _clampHysteresis(hysteresisMs) {
    // An injected scheduler must share the selector's smoothing factor.
    this.scheduler.emaAlpha = _emaAlpha;
  }

  static const double _kDefaultEmaAlpha = 0.2;
  static const int _kDefaultHysteresisMs = 50;

  static double _clampAlpha(double v) {
    if (v.isNaN) return _kDefaultEmaAlpha;
    if (v < 0) return 0.0;
    if (v > 1) return 1.0;
    return v;
  }

  static int _clampHysteresis(int v) => v.clamp(0, 5000);

  /// Observation buffer (injectable for tests / reuse).
  final ProbeHistory history;

  /// Latency ranking backend (injectable for tests).
  final SchedulerWrapper scheduler;

  double _emaAlpha;

  /// EMA smoothing factor, clamped to `[0, 1]` and mirrored to the scheduler.
  double get emaAlpha => _emaAlpha;
  set emaAlpha(double value) {
    _emaAlpha = _clampAlpha(value);
    scheduler.emaAlpha = _emaAlpha;
  }

  int _hysteresisMs;

  /// Minimum improvement (ms) before [best] switches away from the current
  /// node; clamped to `[0, 5000]` to match `AppSettings._normalize`.
  int get hysteresisMs => _hysteresisMs;
  set hysteresisMs(int value) => _hysteresisMs = _clampHysteresis(value);

  /// Last node committed with [adopt].
  String? current;

  /// The single write entry point.
  ///
  /// `0` (blocked) and `-1` (timeout) are still recorded as losses in the
  /// observation window, but are removed from the ranking so a failure can
  /// never masquerade as a low-latency winner.
  Future<void> record(String proxy, int delay) async {
    history.record(proxy, delay);
    if (delay > 0) {
      await scheduler.updateLatency(proxy, delay);
    } else {
      await scheduler.remove(proxy);
    }
  }

  /// Window statistics for one proxy, or `null` if never recorded.
  ProbeStats? statsFor(String proxy) => history.statsFor(proxy);

  /// Pure chooser: never mutates state and never calls the destructive
  /// `SchedulerWrapper.getBestProxy()`. Repeated calls are stable.
  String? best({Iterable<String>? candidates, String? current}) {
    final allowed = candidates?.toSet();
    final usable = scheduler.ranked().where(
      (e) => e.value > 0 && (allowed == null || allowed.contains(e.key)),
    );
    if (usable.isEmpty) return null;
    final top = usable.first;

    final anchor = current ?? this.current;
    if (anchor == null || (allowed != null && !allowed.contains(anchor))) {
      return top.key;
    }
    final anchorLatency = scheduler.smoothedFor(anchor);
    if (anchorLatency == null || anchorLatency <= 0) return top.key;
    if (top.key == anchor) return anchor;
    // Tolerance keeps an exact-threshold boundary from flipping due to EMA
    // floating-point noise (design §8, review focus 2).
    if (anchorLatency - top.value < _hysteresisMs - 1e-9) return anchor;
    return top.key;
  }

  /// Commit [proxy] as the current selection.
  void adopt(String? proxy) => current = proxy;

  /// Immutable snapshot of configuration plus derived EMA/statistics maps.
  SmartSelectorSnapshot snapshot() => SmartSelectorSnapshot(
    emaAlpha: _emaAlpha,
    hysteresisMs: _hysteresisMs,
    current: current,
    ema: Map<String, double>.unmodifiable(
      Map<String, double>.fromEntries(scheduler.ranked()),
    ),
    stats: Map<String, ProbeStats>.unmodifiable(history.statsAll()),
  );

  /// Hot-apply settings changes without clearing observed history.
  void configure({double? emaAlpha, int? hysteresisMs}) {
    if (emaAlpha != null) this.emaAlpha = emaAlpha;
    if (hysteresisMs != null) this.hysteresisMs = hysteresisMs;
  }

  /// Clear ranking state and the committed node, but keep [history].
  /// Observations survive a reconnect; callers wanting a fresh window must
  /// clear the history explicitly.
  void reset() {
    scheduler.reset();
    adopt(null);
  }
}
