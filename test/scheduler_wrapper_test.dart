// test/scheduler_wrapper_test.dart
//
// Tests for the configurable/hysteresis scheduler wrapper. These never need a
// linked Rust dylib: the ranking helpers read the Dart-side mirror, and the
// FFI init failure is swallowed by the wrapper into its documented fallback.

import 'package:flutter_test/flutter_test.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';

void main() {
  setUp(() {
    // reset() clears the shared static scheduler/init flags as well, giving
    // every test a clean slate regardless of what ran before.
    SchedulerWrapper().reset();
  });

  group('EMA alpha', () {
    test('defaults to the public constant and smooths with it', () async {
      final w = SchedulerWrapper();
      expect(SchedulerWrapper.defaultEmaAlpha, 0.2);
      expect(w.emaAlpha, SchedulerWrapper.defaultEmaAlpha);

      await w.updateLatency('A', 100);
      await w.updateLatency('A', 200);
      // 0.2 * 200 + 0.8 * 100 = 120
      expect(w.smoothedFor('A'), closeTo(120.0, 1e-9));
    });

    test('a custom constructor alpha is used on both samples', () async {
      final w = SchedulerWrapper(emaAlpha: 0.5);
      expect(w.emaAlpha, 0.5);
      await w.updateLatency('B', 100);
      await w.updateLatency('B', 300);
      // 0.5 * 300 + 0.5 * 100 = 200
      expect(w.smoothedFor('B'), closeTo(200.0, 1e-9));
    });

    test('alpha setter is read by updateLatency and clamps to [0,1]', () async {
      final w = SchedulerWrapper();
      w.emaAlpha = 2.0;
      expect(w.emaAlpha, 1.0);
      w.emaAlpha = -3.0;
      expect(w.emaAlpha, 0.0);

      // alpha == 0 freezes the first sample regardless of later input.
      await w.updateLatency('C', 100);
      await w.updateLatency('C', 500);
      expect(w.smoothedFor('C'), closeTo(100.0, 1e-9));

      w.emaAlpha = 1.0;
      await w.updateLatency('C', 40);
      expect(w.smoothedFor('C'), 40.0);
    });

    test('constructor clamps out-of-range alpha', () {
      expect(SchedulerWrapper(emaAlpha: 5).emaAlpha, 1.0);
      expect(SchedulerWrapper(emaAlpha: -1).emaAlpha, 0.0);
    });
  });

  group('ranked / smoothedFor / snapshot', () {
    test('ranked is non-destructive, sorted, and ties break by name', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('B', 100);
      await w.updateLatency('A', 100);
      await w.updateLatency('C', 50);

      expect(w.ranked().map((e) => e.key).toList(), ['C', 'A', 'B']);
      expect(w.ranked().map((e) => e.value).toList(), [50.0, 100.0, 100.0]);
      // Repeated reads are stable (nothing was popped).
      expect(w.ranked().length, 3);
      expect(w.smoothedFor('B'), 100.0);
      expect(w.smoothedFor('missing'), isNull);
    });

    test('snapshot returns the same ranking as ranked()', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('z', 30);
      await w.updateLatency('y', 10);
      // MapEntry has identity equality, so compare key/value projections.
      expect(
        w.snapshot().map((e) => e.key).toList(),
        w.ranked().map((e) => e.key).toList(),
      );
      expect(
        w.snapshot().map((e) => e.value).toList(),
        w.ranked().map((e) => e.value).toList(),
      );
      expect(w.snapshot().map((e) => e.key).toList(), ['y', 'z']);
    });
  });

  group('bestProxy hysteresis', () {
    test('returns null with no samples and the best with no current', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      expect(w.bestProxy(), isNull);

      await w.updateLatency('slow', 200);
      await w.updateLatency('fast', 50);
      expect(w.bestProxy(), 'fast');
      expect(w.bestProxy(), 'fast'); // non-destructive, repeatable
      expect(w.smoothedFor('fast'), 50.0);
    });

    test('does not flap when improvement is below hysteresisMs', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('current', 100);
      await w.updateLatency('candidate', 90); // gain 10 < 50
      expect(w.bestProxy(current: 'current', hysteresisMs: 50), 'current');

      await w.updateLatency('candidate', 50); // gain 50 >= 50
      expect(w.bestProxy(current: 'current', hysteresisMs: 50), 'candidate');
    });

    test('switches exactly at the threshold and not one ms below', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('a', 100);
      await w.updateLatency('b', 60); // gain exactly 40
      expect(w.bestProxy(current: 'a', hysteresisMs: 40), 'b');
      expect(w.bestProxy(current: 'a', hysteresisMs: 41), 'a');
    });

    test('hysteresisMs == 0 always selects the best', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('a', 100);
      await w.updateLatency('b', 99);
      expect(w.bestProxy(current: 'a', hysteresisMs: 0), 'b');
    });

    test('an unknown or already-best current falls back to the top', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('b', 50);
      expect(w.bestProxy(current: 'ghost', hysteresisMs: 50), 'b');
      expect(w.bestProxy(current: 'b', hysteresisMs: 50), 'b');
    });
  });

  group('remove / removeProxy', () {
    test('both drop only the named proxy and leave others intact', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('a', 10);
      await w.updateLatency('b', 20);
      expect(w.ranked().map((e) => e.key).toList(), ['a', 'b']);

      await w.remove('a');
      expect(w.smoothedFor('a'), isNull);
      expect(w.ranked().map((e) => e.key).toList(), ['b']);

      await w.removeProxy('b');
      expect(w.smoothedFor('b'), isNull);
      expect(w.ranked(), isEmpty);

      // Removing an unknown proxy is a no-op.
      await w.removeProxy('ghost');
      expect(w.ranked(), isEmpty);
    });
  });

  group('getBestProxy compatibility (destructive pop)', () {
    test('pops lowest latency first and ties by insertion order', () async {
      final w = SchedulerWrapper(emaAlpha: 1.0);
      await w.updateLatency('first', 50);
      await w.updateLatency('second', 50);
      await w.updateLatency('third', 10);

      expect(await w.getBestProxy(), 'third');
      expect(await w.getBestProxy(), 'first');
      expect(await w.getBestProxy(), 'second');
      expect(await w.getBestProxy(), isNull);
    });
  });

  group('reset', () {
    test('clears its own mirrors and the shared static state', () async {
      final a = SchedulerWrapper(emaAlpha: 1.0);
      await a.updateLatency('a', 10);
      final b = SchedulerWrapper(emaAlpha: 1.0);
      await b.updateLatency('b', 20);
      expect(a.smoothedFor('a'), 10.0);
      expect(b.smoothedFor('b'), 20.0);

      a.reset();
      expect(a.ranked(), isEmpty);
      // Per-instance mirrors of other objects are untouched.
      expect(b.smoothedFor('b'), 20.0);
      // Shared static state was cleared: a fresh instance starts clean and
      // still works after reset (re-initializes on demand).
      final c = SchedulerWrapper();
      expect(c.ranked(), isEmpty);
      await c.updateLatency('c', 30);
      expect(c.smoothedFor('c'), 30.0);
    });
  });
}
