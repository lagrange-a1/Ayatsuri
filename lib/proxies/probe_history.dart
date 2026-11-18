/*
 * Per-proxy probe history and window statistics.
 *
 * Pure Dart: no Flutter, dio, Rust or any third-party dependency. Only
 * `dart:core` constructs are used (the public contract permits
 * `dart:convert` too, but no JSON codec is needed here — `toJson`/
 * `fromJson` exchange plain `Map`/`List` values).
 *
 * Contract source: omh-pdoc/feat-observability-plan.md section 1.
 */

/// Default number of samples kept per proxy (ring-buffer capacity).
const int kDefaultProbeHistoryCapacity = 50;

/// Immutable window statistic for one proxy.
///
/// Every non-null numeric field is guaranteed finite. A `null` value means
/// "there were no successful samples in the window".
class ProbeStats {
  const ProbeStats({
    required this.total,
    required this.successes,
    required this.losses,
    required this.min,
    required this.max,
    required this.mean,
    required this.p95,
    required this.jitter,
    required this.last,
    this.lossRate = 0.0,
    this.availability = 0.0,
  });

  /// All samples in the window, including blocked (`0`) and timeout
  /// (`kDelayTimeout`, i.e. `-1`) probes.
  final int total;

  /// Samples with `delay > 0`.
  final int successes;

  /// Samples with `delay <= 0` (blocked + timeout).
  final int losses;

  final double? min;
  final double? max;
  final double? mean;
  final double? p95;

  /// Mean absolute difference between adjacent successful samples;
  /// `0.0` when there are fewer than two successful samples.
  final double? jitter;

  /// Most recent raw sample value, which may be `0` or `-1`.
  final int? last;

  /// `losses / total`, or `0.0` when `total == 0`.
  final double lossRate;

  /// `successes / total`, or `0.0` when `total == 0` (never reports 100%
  /// for a window with no observations).
  final double availability;
}

/// Bounded per-proxy ring buffer of raw probe delays plus derived stats.
class ProbeHistory {
  ProbeHistory({int capacity = kDefaultProbeHistoryCapacity})
    : capacity = capacity.clamp(1, 1000);

  /// Immutable, clamped-to-[1, 1000] capacity applied to **each** proxy.
  final int capacity;

  final Map<String, List<int>> _samples = <String, List<int>>{};

  /// Total number of stored samples across all proxies.
  int get length =>
      _samples.values.fold<int>(0, (sum, list) => sum + list.length);

  bool get isEmpty => length == 0;

  /// Unmodifiable view of the proxies that currently have samples.
  Set<String> get proxies => Set<String>.unmodifiable(_samples.keys);

  /// Append one probe result. `0` (blocked) and `-1` (timeout) are stored
  /// like any other delay; the loss/success split happens in [statsFor].
  void record(String proxy, int delay) {
    final list = _samples.putIfAbsent(proxy, () => <int>[]);
    list.add(delay);
    if (list.length > capacity) {
      list.removeAt(0);
    }
  }

  /// Drop all samples for [proxy], or all samples for every proxy when
  /// omitted. The [capacity] is retained either way.
  void clear([String? proxy]) {
    if (proxy == null) {
      _samples.clear();
    } else {
      _samples.remove(proxy);
    }
  }

  /// Unmodifiable, oldest-to-newest view. Unknown proxies yield an empty
  /// list.
  List<int> samplesFor(String proxy) =>
      List<int>.unmodifiable(_samples[proxy] ?? const <int>[]);

  /// Window statistics, or `null` if [proxy] was never recorded.
  ProbeStats? statsFor(String proxy) {
    final s = _samples[proxy];
    if (s == null) return null;

    final ok = <int>[];
    for (final d in s) {
      if (d > 0) ok.add(d);
    }
    final n = ok.length;
    final total = s.length;
    final losses = total - n;

    double? min;
    double? max;
    double? mean;
    double? p95;
    // n < 2 has no adjacent pair, so jitter is defined as 0.0 (also when
    // there are no successful samples at all).
    var jitter = 0.0;

    if (n > 0) {
      final sorted = List<int>.of(ok)..sort();
      min = sorted.first.toDouble();
      max = sorted.last.toDouble();
      final sum = ok.fold<int>(0, (a, b) => a + b);
      mean = sum / n;

      // Nearest-rank 95th percentile.
      final rank = (0.95 * n).ceil();
      final index = (rank - 1).clamp(0, n - 1);
      p95 = sorted[index].toDouble();

      if (n >= 2) {
        var diffSum = 0;
        for (var i = 1; i < n; i++) {
          diffSum += (ok[i] - ok[i - 1]).abs();
        }
        jitter = diffSum / (n - 1);
      }
    }

    return ProbeStats(
      total: total,
      successes: n,
      losses: losses,
      min: min,
      max: max,
      mean: mean,
      p95: p95,
      jitter: jitter,
      last: s.isEmpty ? null : s.last,
      lossRate: total == 0 ? 0.0 : losses / total,
      availability: total == 0 ? 0.0 : n / total,
    );
  }

  /// Statistics for every proxy that currently has samples.
  Map<String, ProbeStats> statsAll() {
    final out = <String, ProbeStats>{};
    for (final key in _samples.keys) {
      final st = statsFor(key);
      if (st != null) out[key] = st;
    }
    return out;
  }

  Map<String, dynamic> toJson() {
    final samples = <String, dynamic>{};
    for (final entry in _samples.entries) {
      samples[entry.key] = List<int>.of(entry.value);
    }
    return <String, dynamic>{'v': 1, 'capacity': capacity, 'samples': samples};
  }

  /// Tolerant deserialization: never throws on malformed input.
  factory ProbeHistory.fromJson(Map<String, dynamic> json) {
    var capacity = kDefaultProbeHistoryCapacity;
    final rawCapacity = json['capacity'];
    if (rawCapacity is int && rawCapacity >= 1 && rawCapacity <= 1000) {
      capacity = rawCapacity;
    }

    final history = ProbeHistory(capacity: capacity);
    final rawSamples = json['samples'];
    if (rawSamples is Map) {
      for (final entry in rawSamples.entries) {
        if (entry.key is! String) continue;
        final key = entry.key as String;
        final value = entry.value;
        if (value is! List) continue;

        final list = <int>[];
        for (final e in value) {
          if (e is int) {
            list.add(e);
          } else if (e is double && e.isFinite && e == e.roundToDouble()) {
            list.add(e.toInt());
          }
        }
        if (list.isEmpty) continue;
        if (list.length > capacity) {
          list.removeRange(0, list.length - capacity);
        }
        history._samples[key] = list;
      }
    }
    return history;
  }
}
