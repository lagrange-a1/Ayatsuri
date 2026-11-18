// test/scheduler_wrapper_test.dart
//
// Tests for the Rust-backed scheduler wrapper. These run without a linked
// dylib: the wrapper detects the missing library and uses its Dart twin,
// which implements the same scoring rules as rust/scheduler/src/lib.rs.

import 'package:flutter_test/flutter_test.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';

RoutingConfig cfg({
  double alpha = 1.0,
  double hysteresis = 50,
  int cooldown = 0,
}) => RoutingConfig(
  alpha: alpha,
  hysteresisMs: hysteresis,
  cooldownMs: cooldown,
  jitterWeight: 0,
  exploreBonusMs: 0,
);

void main() {
  setUp(() {
    SchedulerWrapper.resetForTests();
  });

  group('EMA and jitter', () {
    test('defaults to the public constants and smooths with alpha', () async {
      final w = SchedulerWrapper();
      expect(SchedulerWrapper.defaultEmaAlpha, 0.2);
      expect(w.emaAlpha, SchedulerWrapper.defaultEmaAlpha);
      await w.observe('A', 100);
      await w.observe('A', 200);
      // 0.2 * 200 + 0.8 * 100 = 120
      expect(w.smoothedFor('A'), closeTo(120.0, 1e-9));
    });

    test('custom config alpha and clamps are honoured', () async {
      final w = SchedulerWrapper(config: cfg(alpha: 0.5));
      await w.observe('B', 100);
      await w.observe('B', 300);
      expect(w.smoothedFor('B'), 200.0);
      w.configure(cfg(alpha: 5));
      expect(w.emaAlpha, 1.0);
      w.configure(cfg(alpha: -3));
      expect(w.emaAlpha, 0.0);
    });

    test('non-finite config values are clamped like Rust normalized()', () {
      final cfg = RoutingConfig(
        alpha: double.nan,
        hysteresisMs: double.nan,
        jitterWeight: double.nan,
        failurePenaltyMs: double.infinity,
        stalePenaltyMs: double.nan,
        exploreBonusMs: double.negativeInfinity,
        cooldownMs: 9_999_999,
        staleAfterMs: 1,
        exploreMinSamples: 0,
      ).normalized;
      expect(cfg.alpha, 0.2);
      expect(cfg.hysteresisMs, 50.0);
      expect(cfg.jitterWeight, 0.0);
      // Non-finite values fall back to the lower bound on both backends
      // (Rust's c() and Dart's _finite): inf and -inf both become lo.
      expect(cfg.failurePenaltyMs, 0.0);
      expect(cfg.stalePenaltyMs, 0.0);
      expect(cfg.exploreBonusMs, 0.0);
      expect(cfg.cooldownMs, 3_600_000);
      expect(cfg.staleAfterMs, 1_000);
      expect(cfg.exploreMinSamples, 1);
    });

    test('jitter tracks the mean absolute deviation', () async {
      final w = SchedulerWrapper(config: cfg(alpha: 0.5));
      await w.observe('J', 100);
      await w.observe('J', 200);
      final rank = w.statsFor('J')!;
      expect(rank.ewma, 150.0);
      expect(rank.jitter, 50.0);
      expect(rank.samples, 2);
    });
  });

  group('ranking', () {
    test(
      'rank is sorted, non-destructive and filters unavailable nodes',
      () async {
        final w = SchedulerWrapper(config: cfg());
        await w.observe('slow', 200);
        await w.observe('fast', 50);
        final first = await w.rank(['slow', 'fast']);
        expect(first.map((e) => e.proxy), ['fast', 'slow']);
        expect((await w.rank(['slow', 'fast'])).length, 2);
        expect(w.smoothedFor('slow'), 200.0);
      },
    );

    test('failed nodes get penalised and are eventually excluded', () async {
      final w = SchedulerWrapper(config: cfg());
      await w.observe('bad', 50);
      await w.observe('good', 60);
      await w.fail('bad');
      await w.fail('bad');
      var rows = await w.rank(['bad', 'good']);
      expect(rows.first.proxy, 'good');
      await w.fail('bad', timeout: true);
      rows = await w.rank(['bad', 'good']);
      expect(rows.map((e) => e.proxy), ['good']);
      // The legacy ranked()/snapshot() view must agree with rank(): a node
      // disabled by failures never appears as a usable candidate.
      expect(w.ranked().map((e) => e.key), ['good']);
      expect(w.snapshot().map((e) => e.key), ['good']);
      await w.record('bad', 50);
      expect((await w.rank(['bad', 'good'])).length, 2);
      expect(w.ranked(), hasLength(2));
    });

    test('low-confidence nodes are flagged', () async {
      final w = SchedulerWrapper(config: cfg());
      await w.observe('new', 80);
      expect(w.statsFor('new')!.lowConfidence, isTrue);
      for (var i = 0; i < 3; i++) {
        await w.observe('new', 80);
      }
      expect(w.statsFor('new')!.lowConfidence, isFalse);
    });
  });

  group('best with hysteresis and cooldown', () {
    test('returns null with no samples and the best with no current', () async {
      final w = SchedulerWrapper(config: cfg());
      expect(await w.best(['ghost']), isNull);
      await w.observe('slow', 200);
      await w.observe('fast', 50);
      expect(await w.best(['slow', 'fast']), 'fast');
      expect(await w.best(['slow', 'fast']), 'fast');
    });

    test('keeps current until improvement exceeds hysteresis', () async {
      final w = SchedulerWrapper(config: cfg(hysteresis: 50));
      await w.observe('current', 100);
      await w.observe('candidate', 90);
      expect(
        await w.best(['current', 'candidate'], current: 'current'),
        'current',
      );
      await w.observe('candidate', 40);
      // A third identical sample drives jitter (and its score penalty) to 0.
      await w.observe('candidate', 40);
      expect(
        await w.best(['current', 'candidate'], current: 'current'),
        'candidate',
      );
    });

    test(
      'cooldown blocks a switch unless the current node is unavailable',
      () async {
        final w = SchedulerWrapper(
          config: cfg(hysteresis: 10, cooldown: 60_000),
        );
        await w.observe('a', 100);
        await w.observe('b', 30);
        expect(await w.best(['a', 'b'], current: 'a'), 'b');
        await w.observe('a', 1);
        expect(await w.best(['a', 'b'], current: 'b'), 'b');
        await w.fail('b');
        await w.fail('b');
        await w.fail('b');
        expect(await w.best(['a', 'b'], current: 'b'), 'a');
      },
    );
  });

  group('lifecycle', () {
    test('remove drops only the named proxy', () async {
      final w = SchedulerWrapper(config: cfg());
      await w.observe('a', 10);
      await w.observe('b', 20);
      await w.remove('a');
      expect(w.smoothedFor('a'), isNull);
      expect((await w.rank(['a', 'b'])).map((e) => e.proxy), ['b']);
      await w.removeProxy('b');
      expect(await w.rank(['a', 'b']), isEmpty);
    });

    test('reset clears per-instance state and the static backend', () async {
      final a = SchedulerWrapper(config: cfg());
      await a.observe('a', 10);
      final b = SchedulerWrapper(config: cfg());
      await b.observe('b', 20);
      a.reset();
      expect(a.ranked(), isEmpty);
      expect(b.smoothedFor('b'), 20.0);
      final c = SchedulerWrapper(config: cfg());
      await c.observe('c', 30);
      expect(c.smoothedFor('c'), 30.0);
    });
  });
}
