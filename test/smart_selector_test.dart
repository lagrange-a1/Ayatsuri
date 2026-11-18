/*
 * Combined tests for SmartSelector: probe history + scheduler ranking,
 * hysteresis, configuration and snapshot semantics. Pure Dart — no FFI.
 */

import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/proxies/probe_history.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/proxies/smart_selector.dart';

/// Deterministic scheduler: latencies are set directly where a test needs an
/// exact hysteresis boundary, EMA is applied everywhere else.
class FakeScheduler extends SchedulerWrapper {
  final Map<String, double> latencies = <String, double>{};
  double _alpha = 0.2;
  double _hysteresis = 50;

  @override
  Iterable<String> get knownProxies => latencies.keys;

  @override
  Future<void> observe(String proxy, int latencyMs) async {
    final old = latencies[proxy];
    latencies[proxy] = old == null
        ? latencyMs.toDouble()
        : _alpha * latencyMs + (1 - _alpha) * old;
  }

  @override
  Future<void> fail(String proxy, {bool timeout = false}) async {
    latencies.remove(proxy);
  }

  @override
  double? smoothedFor(String proxy) => latencies[proxy];

  @override
  List<MapEntry<String, double>> ranked() {
    final entries = latencies.entries.toList()
      ..sort((a, b) {
        final byLatency = a.value.compareTo(b.value);
        return byLatency != 0 ? byLatency : a.key.compareTo(b.key);
      });
    return List<MapEntry<String, double>>.unmodifiable(entries);
  }

  @override
  NodeRank? statsFor(String proxy) {
    final v = latencies[proxy];
    if (v == null) return null;
    return NodeRank(
      proxy: proxy,
      ewma: v,
      jitter: 0,
      score: v,
      samples: 3,
      failures: 0,
      ageMs: 0,
      available: true,
    );
  }

  @override
  Future<List<NodeRank>> rank(Iterable<String> candidates) async {
    final allowed = candidates.toSet();
    final rows =
        latencies.entries
            .where((e) => allowed.contains(e.key))
            .map(
              (e) => NodeRank(
                proxy: e.key,
                ewma: e.value,
                jitter: 0,
                score: e.value,
                samples: 3,
                failures: 0,
                ageMs: 0,
                available: true,
              ),
            )
            .toList()
          ..sort((a, b) {
            final byScore = a.score.compareTo(b.score);
            return byScore != 0 ? byScore : a.proxy.compareTo(b.proxy);
          });
    return rows;
  }

  @override
  Future<String?> best(Iterable<String> candidates, {String? current}) async {
    final rows = await rank(candidates);
    if (rows.isEmpty) return null;
    final top = rows.first.proxy;
    if (current == null || !rows.any((r) => r.proxy == current)) return top;
    final held = latencies[current]!;
    if (held - rows.first.score < _hysteresis) return current;
    return top;
  }

  @override
  void configure(RoutingConfig config) {
    _alpha = config.alpha.clamp(0.0, 1.0);
    _hysteresis = config.hysteresisMs.clamp(0, 5000);
  }

  @override
  void reset() => latencies.clear();
}

void main() {
  late FakeScheduler scheduler;
  late SmartSelector selector;

  setUp(() {
    scheduler = FakeScheduler();
    selector = SmartSelector(scheduler: scheduler);
  });

  test('defaults match AppSettings normalization', () {
    final fresh = SmartSelector();
    expect(fresh.emaAlpha, 0.2);
    expect(fresh.hysteresisMs, 50);
    expect(fresh.current, isNull);
    expect(fresh.history.isEmpty, isTrue);
  });

  test('record feeds history and the EMA ranking', () async {
    await selector.record('A', 100);
    await selector.record('A', 200);

    final stats = selector.statsFor('A')!;
    expect(stats.total, 2);
    expect(stats.successes, 2);
    expect(stats.losses, 0);
    expect(stats.last, 200);
    expect(stats.availability, 1.0);
    expect(scheduler.latencies['A'], closeTo(120, 1e-9));
  });

  test('blocked and timeout count as losses and leave the ranking', () async {
    await selector.record('A', 100);
    await selector.record('A', 0);
    var stats = selector.statsFor('A')!;
    expect(stats.total, 2);
    expect(stats.losses, 1);
    expect(stats.availability, 0.5);
    expect(await selector.best(), isNull);

    await selector.record('A', -1);
    stats = selector.statsFor('A')!;
    expect(stats.total, 3);
    expect(stats.losses, 2);
    expect(stats.availability, closeTo(1 / 3, 1e-9));
    expect(stats.p95, 100.0);
    expect(stats.last, -1);
    expect(await selector.best(), isNull);
  });

  test('a success after a loss re-enters the ranking', () async {
    await selector.record('A', 100);
    await selector.record('A', 0);
    expect(await selector.best(), isNull);

    await selector.record('A', 300);
    expect(scheduler.latencies['A'], 300.0);
    expect(await selector.best(), 'A');
    expect(selector.statsFor('A')!.p95, 300.0);
  });

  test('best switches at the exact hysteresis boundary', () async {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 50;
    selector.adopt('A');

    expect(selector.hysteresisMs, 50);
    expect(await selector.best(), 'B');

    selector.configure(hysteresisMs: 51);
    expect(await selector.best(), 'A');

    selector.configure(hysteresisMs: 49);
    expect(await selector.best(), 'B');
  });

  test('hysteresisMs = 0 always picks the best', () async {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 99.9;
    selector.configure(hysteresisMs: 0);
    selector.adopt('A');
    expect(await selector.best(), 'B');
  });

  test('best honours the candidate filter', () async {
    scheduler.latencies['A'] = 300;
    scheduler.latencies['B'] = 50;
    expect(await selector.best(), 'B');
    expect(await selector.best(candidates: const {'A'}), 'A');
    expect(await selector.best(candidates: const {'Z'}), isNull);
  });

  test('best uses the adopted current as its default anchor', () async {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 50;
    selector.configure(hysteresisMs: 0);
    selector.adopt('A');
    expect(await selector.best(), 'B');
    selector.adopt('B');
    expect(await selector.best(), 'B');
    expect(await selector.best(current: 'A'), 'B');
    expect(selector.current, 'B');
  });

  test('best is a pure suggestion — repeatable, nothing popped', () async {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 50;
    expect(await selector.best(), 'B');
    expect(await selector.best(), 'B');
    expect(scheduler.latencies, hasLength(2));
  });

  test('snapshot exposes unmodifiable EMA and stats maps', () async {
    await selector.record('A', 100);
    selector.adopt('A');
    final snap = selector.snapshot();
    expect(snap.emaAlpha, 0.2);
    expect(snap.hysteresisMs, 50);
    expect(snap.current, 'A');
    expect(snap.ema['A'], 100.0);
    expect(snap.stats['A']!.total, 1);
    expect(() => snap.ema['B'] = 1.0, throwsA(isA<UnsupportedError>()));
    expect(
      () => snap.stats['B'] = snap.stats['A']!,
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('configure clamps to settings ranges and preserves history', () async {
    await selector.record('A', 100);

    selector.configure(emaAlpha: 5, hysteresisMs: -1);
    expect(selector.emaAlpha, 1.0);
    expect(selector.hysteresisMs, 0);

    selector.configure(emaAlpha: -5, hysteresisMs: 100000);
    expect(selector.emaAlpha, 0.0);
    expect(selector.hysteresisMs, 5000);

    expect(selector.statsFor('A')!.total, 1);
  });

  test('reset clears ranking and current but keeps history', () async {
    await selector.record('A', 100);
    selector.adopt('A');
    expect(await selector.best(), 'A');

    selector.reset();
    expect(selector.current, isNull);
    expect(await selector.best(), isNull);
    expect(scheduler.latencies, isEmpty);
    expect(selector.statsFor('A')!.total, 1);
  });

  test('explicitly injected history is shared, not copied', () async {
    final history = ProbeHistory(capacity: 2);
    final combined = SmartSelector(history: history, scheduler: scheduler);
    await combined.record('A', 1);
    await combined.record('A', 2);
    await combined.record('A', 3);
    expect(combined.history, same(history));
    expect(history.samplesFor('A'), [2, 3]);
  });
}
