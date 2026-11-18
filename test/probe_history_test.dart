/*
 * Unit tests for `lib/proxies/probe_history.dart`.
 *
 * Statistics expectations follow the precise formulas in
 * omh-pdoc/feat-observability-plan.md section 1.3.
 */

import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/proxies/probe_history.dart';

void main() {
  group('capacity', () {
    test('default and clamped capacity', () {
      expect(kDefaultProbeHistoryCapacity, 50);
      expect(ProbeHistory().capacity, 50);
      expect(ProbeHistory(capacity: 0).capacity, 1);
      expect(ProbeHistory(capacity: -7).capacity, 1);
      expect(ProbeHistory(capacity: 5000).capacity, 1000);
      expect(ProbeHistory(capacity: 120).capacity, 120);
    });

    test('per-proxy overflow drops the oldest sample', () {
      final h = ProbeHistory(capacity: 3);
      for (final d in [10, 20, 30, 40, 50]) {
        h.record('HK', d);
      }
      expect(h.samplesFor('HK'), [30, 40, 50]);

      // Capacity is per-proxy, not global.
      h.record('CN', 99);
      expect(h.samplesFor('CN'), [99]);
      expect(h.samplesFor('HK'), [30, 40, 50]);
      expect(h.length, 4);
    });

    test('samplesFor is an unmodifiable view', () {
      final h = ProbeHistory()..record('HK', 10);
      final view = h.samplesFor('HK');
      expect(() => view.add(999), throwsA(isA<UnsupportedError>()));
      expect(h.samplesFor('HK'), [10]);
      expect(h.samplesFor('missing'), isEmpty);
    });

    test('clear one proxy or all, capacity survives', () {
      final h = ProbeHistory(capacity: 4);
      h
        ..record('HK', 10)
        ..record('CN', 20);
      h.clear('HK');
      expect(h.samplesFor('HK'), isEmpty);
      expect(h.samplesFor('CN'), [20]);

      h.clear();
      expect(h.isEmpty, isTrue);
      expect(h.length, 0);
      expect(h.capacity, 4);
      // Usable again after clear.
      h.record('HK', 30);
      expect(h.samplesFor('HK'), [30]);
    });

    test('proxies is an unmodifiable key view', () {
      final h = ProbeHistory()
        ..record('HK', 1)
        ..record('CN', 2);
      expect(h.proxies, {'HK', 'CN'});
      expect(() => h.proxies.add('JP'), throwsA(isA<UnsupportedError>()));
    });
  });

  group('statsFor', () {
    test('returns null for a never-recorded proxy', () {
      expect(ProbeHistory().statsFor('HK'), isNull);
    });

    test('success/loss split, min/max/mean, last and rates', () {
      final h = ProbeHistory();
      for (final d in [120, 135, 140, 0, -1]) {
        h.record('HK', d);
      }
      final s = h.statsFor('HK')!;
      expect(s.total, 5);
      expect(s.successes, 3);
      expect(s.losses, 2);
      expect(s.min, 120.0);
      expect(s.max, 140.0);
      expect(s.mean, closeTo(395 / 3, 1e-12));
      expect(s.last, -1); // raw value kept for the UI
      expect(s.lossRate, closeTo(2 / 5, 1e-12));
      expect(s.availability, closeTo(3 / 5, 1e-12));
      expect(s.availability, closeTo(1 - s.lossRate, 1e-12));
    });

    test('jitter is mean absolute difference of adjacent successes', () {
      final h = ProbeHistory();
      for (final d in [120, 135, 140]) {
        h.record('HK', d);
      }
      // |135-120| = 15, |140-135| = 5 -> (15+5)/2 = 10
      expect(h.statsFor('HK')!.jitter, 10.0);
    });

    test('p95 nearest-rank boundary (n=1 and n=20)', () {
      final one = ProbeHistory()..record('A', 42);
      expect(one.statsFor('A')!.p95, 42.0);
      expect(one.statsFor('A')!.jitter, 0.0);

      final h = ProbeHistory();
      for (var i = 1; i <= 20; i++) {
        h.record('A', i);
      }
      // rank = ceil(0.95*20) = 19; index = 18 -> sorted[18] = 19
      expect(h.statsFor('A')!.p95, 19.0);
    });

    test('p95 ignores losses and uses the success window only', () {
      final h = ProbeHistory();
      for (final d in [0, -1, 10, 20, 30, 40]) {
        h.record('A', d);
      }
      // ok = [10,20,30,40], n=4, rank=ceil(3.8)=4, index=3 -> 40
      expect(h.statsFor('A')!.p95, 40.0);
      expect(h.statsFor('A')!.min, 10.0);
      expect(h.statsFor('A')!.max, 40.0);
    });

    test(
      'all-loss window: null distribution stats, 0.0 jitter, 0 availability',
      () {
        final h = ProbeHistory();
        h
          ..record('A', 0)
          ..record('A', -1);
        final s = h.statsFor('A')!;
        expect(s.total, 2);
        expect(s.successes, 0);
        expect(s.losses, 2);
        expect(s.min, isNull);
        expect(s.max, isNull);
        expect(s.mean, isNull);
        expect(s.p95, isNull);
        // Section 1.3 formula: n < 2 -> 0.0 (see handoff note re 1.5 wording).
        expect(s.jitter, 0.0);
        expect(s.last, -1);
        expect(s.lossRate, 1.0);
        expect(s.availability, 0.0);
      },
    );

    test('availability does not fabricate 100% for an empty window', () {
      final h = ProbeHistory();
      h.clear('never');
      expect(h.statsFor('never'), isNull);
      // The constructor defaults are the empty-window values.
      const empty = ProbeStats(
        total: 0,
        successes: 0,
        losses: 0,
        min: null,
        max: null,
        mean: null,
        p95: null,
        jitter: 0.0,
        last: null,
      );
      expect(empty.lossRate, 0.0);
      expect(empty.availability, 0.0);
    });

    test('statsAll only reports proxies that have samples', () {
      final h = ProbeHistory()
        ..record('HK', 10)
        ..record('CN', 0);
      h.clear('HK');
      final all = h.statsAll();
      expect(all.keys, {'CN'});
      expect(all['CN']!.total, 1);
      expect(all['CN']!.losses, 1);
    });
  });

  group('JSON round trip', () {
    test('toJson shape and exact round trip', () {
      final h = ProbeHistory(capacity: 3);
      for (final d in [120, 135, 140, 0]) {
        h.record('HK 2', d);
      }
      h.record('CN 1', 400);

      final json = h.toJson();
      expect(json['v'], 1);
      expect(json['capacity'], 3);
      final samples = json['samples'] as Map<String, dynamic>;
      expect(samples.keys.toList(), ['HK 2', 'CN 1']);
      // Oldest dropped by capacity=3: [135,140,0]
      expect(samples['HK 2'], [135, 140, 0]);

      final restored = ProbeHistory.fromJson(json);
      expect(restored.capacity, 3);
      expect(restored.samplesFor('HK 2'), h.samplesFor('HK 2'));
      expect(restored.samplesFor('CN 1'), h.samplesFor('CN 1'));
      expect(restored.toJson(), h.toJson());
    });

    test('fromJson truncates long lists to the last capacity items', () {
      final h = ProbeHistory.fromJson({
        'v': 1,
        'capacity': 2,
        'samples': {
          'A': [1, 2, 3, 4, 5],
        },
      });
      expect(h.samplesFor('A'), [4, 5]);
    });

    test('fromJson tolerates malformed input without throwing', () {
      // Non-map-ish samples payloads produce an empty default instance.
      for (final bad in [
        <String, dynamic>{},
        <String, dynamic>{'samples': 'not a map'},
        <String, dynamic>{
          'samples': [1, 2, 3],
        },
        <String, dynamic>{'capacity': 'big', 'samples': <String, dynamic>{}},
        <String, dynamic>{'capacity': 0, 'samples': <String, dynamic>{}},
        <String, dynamic>{'capacity': 1001, 'samples': <String, dynamic>{}},
        <String, dynamic>{'capacity': 1.5, 'samples': <String, dynamic>{}},
      ]) {
        expect(() => ProbeHistory.fromJson(bad), returnsNormally);
        final h = ProbeHistory.fromJson(bad);
        expect(h.capacity, 50);
        expect(h.isEmpty, isTrue);
      }
    });

    test('fromJson filters keys, elements and unknown top-level fields', () {
      final samples = <dynamic, dynamic>{
        'ok': <dynamic>[10, 20.0, 30.5, 'x', null, true, -1],
        42: <dynamic>[1, 2], // non-String key skipped
        'notAList': 123, // non-List value skipped
        'allBad': <dynamic>['x', null, 1.5], // empties are skipped
      };
      final h = ProbeHistory.fromJson(<String, dynamic>{
        'v': 99,
        'capacity': 5,
        'samples': samples,
        'unknown': 'ignored',
      });
      expect(h.capacity, 5);
      expect(h.samplesFor('ok'), [10, 20, -1]);
      expect(h.proxies, {'ok'});
      expect(h.samplesFor('42'), isEmpty);
    });

    test('fromJson honours a valid capacity', () {
      final h = ProbeHistory.fromJson(<String, dynamic>{
        'v': 1,
        'capacity': 7,
        'samples': <String, dynamic>{},
      });
      expect(h.capacity, 7);
    });
  });
}
