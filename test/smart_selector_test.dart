/*
 * Combined tests for SmartSelector: probe history + scheduler ranking,
 * hysteresis, configuration and snapshot semantics. Pure Dart — no FFI.
 */

import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/proxies/probe_history.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/proxies/smart_selector.dart';

/// Deterministic scheduler: no Rust FFI, latencies set directly where a
/// test needs exact hysteresis boundaries, EMA otherwise.
class FakeScheduler extends SchedulerWrapper {
  final Map<String, double> latencies = <String, double>{};

  @override
  Future<void> updateLatency(String proxy, int latency) async {
    final old = latencies[proxy];
    latencies[proxy] = old == null
        ? latency.toDouble()
        : emaAlpha * latency + (1 - emaAlpha) * old;
  }

  @override
  Future<void> remove(String proxy) async => latencies.remove(proxy);

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
    // alpha 0.2: first sample is taken verbatim, then 0.2*200 + 0.8*100.
    expect(scheduler.latencies['A'], closeTo(120, 1e-9));
  });

  test('blocked and timeout count as losses and leave the ranking', () async {
    await selector.record('A', 100);
    await selector.record('A', 0); // 503 -> blocked

    var stats = selector.statsFor('A')!;
    expect(stats.total, 2);
    expect(stats.successes, 1);
    expect(stats.losses, 1);
    expect(stats.availability, 0.5);
    expect(stats.last, 0);
    expect(selector.best(), isNull); // no positive latency left

    await selector.record('A', -1); // 504 -> timeout
    stats = selector.statsFor('A')!;
    expect(stats.total, 3);
    expect(stats.losses, 2);
    expect(stats.availability, closeTo(1 / 3, 1e-9));
    expect(stats.p95, 100.0); // p95 over successful samples only
    expect(stats.last, -1);
    expect(selector.best(), isNull);
  });

  test(
    'a success after a loss re-enters the ranking with a fresh EMA',
    () async {
      await selector.record('A', 100);
      await selector.record('A', 0);
      expect(selector.best(), isNull);

      await selector.record('A', 300);
      expect(scheduler.latencies['A'], 300.0);
      expect(selector.best(), 'A');
      // Successful samples are [100, 300] -> nearest-rank p95 is 300.
      expect(selector.statsFor('A')!.p95, 300.0);
    },
  );

  test('best switches at the exact hysteresis boundary', () {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 50;
    selector.adopt('A');

    // Improvement is exactly 50 == hysteresisMs -> switch.
    expect(selector.hysteresisMs, 50);
    expect(selector.best(), 'B');

    // One millisecond more required -> hold the current node.
    selector.configure(hysteresisMs: 51);
    expect(selector.best(), 'A');

    // One millisecond less required -> switch.
    selector.configure(hysteresisMs: 49);
    expect(selector.best(), 'B');
  });

  test('hysteresisMs = 0 always picks the best', () {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 99.9;
    selector.configure(hysteresisMs: 0);
    selector.adopt('A');
    expect(selector.best(), 'B');
  });

  test(
    'best honours the candidate filter and skips non-positive latencies',
    () {
      scheduler.latencies['A'] = 300;
      scheduler.latencies['B'] = 0; // blocked nodes never win
      scheduler.latencies['C'] = -1; // timeouts never win
      expect(selector.best(), 'A');
      expect(selector.best(candidates: const {'A'}), 'A');
      expect(selector.best(candidates: const {'Z'}), isNull);
    },
  );

  test('best uses the adopted current as its default anchor', () {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 50;
    selector.configure(hysteresisMs: 0);
    selector.adopt('A');
    expect(selector.best(), 'B');
    selector.adopt('B');
    expect(selector.best(), 'B');
    // An explicit current overrides the adopted one without committing it.
    expect(selector.best(current: 'A'), 'B');
    expect(selector.current, 'B');
  });

  test('best is a pure suggestion — repeatable, nothing popped', () {
    scheduler.latencies['A'] = 100;
    scheduler.latencies['B'] = 50;
    expect(selector.best(), 'B');
    expect(selector.best(), 'B');
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
    expect(scheduler.emaAlpha, 1.0); // mirrored to the scheduler
    expect(selector.hysteresisMs, 0);

    selector.configure(emaAlpha: -5, hysteresisMs: 100000);
    expect(selector.emaAlpha, 0.0);
    expect(selector.hysteresisMs, 5000);

    expect(selector.statsFor('A')!.total, 1); // observations survive
  });

  test('reset clears ranking and current but keeps history', () async {
    await selector.record('A', 100);
    selector.adopt('A');
    expect(selector.best(), 'A');

    selector.reset();
    expect(selector.current, isNull);
    expect(selector.best(), isNull);
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
