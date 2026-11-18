/*
 * SmartSelector — combines probe observation (ProbeHistory) with latency
 * ranking (SchedulerWrapper) into one pure-Dart, testable decision surface.
 *
 * The ranking/decision arithmetic lives in Rust when the native library is
 * available and in an equivalent Dart implementation otherwise; this class
 * only supplies the observation window and the commit semantics.
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
    RoutingConfig? config,
    double emaAlpha = 0.2,
    int hysteresisMs = 50,
    this.current,
  }) : history = history ?? ProbeHistory(),
       scheduler = scheduler ?? SchedulerWrapper(config: config),
       _config = config ?? RoutingConfig.defaults {
    // An injected scheduler must share the selector's configuration.
    this.scheduler.configure(
      _effectiveConfig(_config, emaAlpha: emaAlpha, hysteresisMs: hysteresisMs),
    );
  }

  static RoutingConfig _effectiveConfig(
    RoutingConfig base, {
    double? emaAlpha,
    int? hysteresisMs,
  }) {
    var out = base;
    if (emaAlpha != null) out = out.copyWith(alpha: emaAlpha);
    if (hysteresisMs != null) {
      out = out.copyWith(hysteresisMs: hysteresisMs.toDouble());
    }
    return out;
  }

  /// Observation buffer (injectable for tests / reuse).
  final ProbeHistory history;

  /// Latency ranking backend (injectable for tests).
  final SchedulerWrapper scheduler;

  RoutingConfig _config;

  RoutingConfig get routingConfig => _config;

  double get emaAlpha => _config.safeAlpha;
  int get hysteresisMs => _config.safeHysteresis.toInt();

  /// Last node committed with [adopt].
  String? current;

  /// The single write entry point.
  ///
  /// `0` (blocked) and `-1` (timeout) are still recorded as losses in the
  /// observation window, but are excluded from ranking until the node has
  /// enough successful probes to recover.
  Future<void> record(String proxy, int delay) async {
    history.record(proxy, delay);
    await scheduler.record(proxy, delay);
  }

  /// Window statistics for one proxy, or `null` if never recorded.
  ProbeStats? statsFor(String proxy) => history.statsFor(proxy);

  /// Pure chooser: never mutates state and never commits a node.
  ///
  /// The Rust core (or its Dart twin) applies EWMA, jitter, failure penalty,
  /// exploration bonus, hysteresis and switch cooldown in one place.
  Future<String?> best({Iterable<String>? candidates, String? current}) async {
    final allowed = candidates?.toSet();
    if (allowed != null && allowed.isEmpty) return null;
    final anchor = current ?? this.current;
    final usable = (allowed ?? scheduler.knownProxies).toList();
    return scheduler.best(usable, current: anchor);
  }

  /// Commit [proxy] as the current selection.
  void adopt(String? proxy) => current = proxy;

  /// Immutable snapshot of configuration plus derived EMA/statistics maps.
  SmartSelectorSnapshot snapshot() => SmartSelectorSnapshot(
    emaAlpha: emaAlpha,
    hysteresisMs: hysteresisMs,
    current: current,
    ema: Map<String, double>.unmodifiable(
      Map<String, double>.fromEntries(scheduler.ranked()),
    ),
    stats: Map<String, ProbeStats>.unmodifiable(history.statsAll()),
  );

  /// Hot-apply settings changes without clearing observed history.
  void configure({double? emaAlpha, int? hysteresisMs, RoutingConfig? config}) {
    _config = _effectiveConfig(
      config ?? _config,
      emaAlpha: emaAlpha,
      hysteresisMs: hysteresisMs,
    );
    scheduler.configure(_config);
  }

  /// Clear ranking state and the committed node, but keep [history].
  void reset() {
    scheduler.reset();
    adopt(null);
  }
}
