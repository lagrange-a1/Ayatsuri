// test/scheduler_dashboard_test.dart
//
// Widget tests for the user-visible scheduling dashboard: rank fields,
// backend badge copy, the auto-select commit path (put + adopt), and the
// opt-in background auto-schedule cycle.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/info/scheduler_dashboard.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';
import 'package:ayatsuri/proxies/proxy_service.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/proxies/smart_selector.dart';

/// Minimal controller: one Selector (pin-able) plus one automatic pool that
/// must never be offered to the group picker or the auto-select PUT.
class FakeMihomoApi extends MihomoAPI {
  final List<(String, String)> selectCalls = <(String, String)>[];

  final List<Map<String, dynamic>> groups = <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'MAIN',
      'type': 'Selector',
      'all': <String>['A', 'B', 'C'],
      'now': 'A',
    },
    <String, dynamic>{
      'name': 'AUTO',
      'type': 'URLTest',
      'all': <String>['A', 'B'],
      'now': 'B',
    },
  ];

  @override
  Future<Response> getProxies() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <String, dynamic>{
          for (final name in <String>['A', 'B', 'C'])
            name: <String, dynamic>{
              'name': name,
              'type': 'Direct',
              'alive': true,
            },
        },
      },
    ),
  );

  @override
  Future<Response> getGroups() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{'proxies': groups},
    ),
  );

  @override
  Future<Response> selectProxy(String name, {required String proxyName}) {
    selectCalls.add((name, proxyName));
    for (final group in groups) {
      if (group['name'] == name) group['now'] = proxyName;
    }
    return Future<Response>.value(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(),
        data: <String, dynamic>{},
      ),
    );
  }
}

/// Deterministic backend: injectable rustActive flag plus fixed rank/best
/// results, and records the arguments the dashboard passes in.
class FakeScheduler extends SchedulerWrapper {
  FakeScheduler({
    this.rust = true,
    this.rows = const <NodeRank>[],
    this.bestProxy,
  });

  bool rust;
  List<NodeRank> rows;
  String? bestProxy;

  Iterable<String>? lastCandidates;
  String? lastCurrent;
  int rankCalls = 0;

  @override
  bool get rustActive => rust;

  @override
  void configure(RoutingConfig config) {}

  @override
  Future<List<NodeRank>> rank(Iterable<String> candidates) async {
    rankCalls++;
    lastCandidates = candidates;
    final allowed = candidates.toSet();
    return rows.where((r) => allowed.contains(r.proxy)).toList();
  }

  @override
  Future<String?> best(Iterable<String> candidates, {String? current}) async {
    lastCandidates = candidates;
    lastCurrent = current;
    return bestProxy;
  }
}

/// A ProxySelection that records probe / bestProxy / load calls without any
/// real HTTP delay. `best` is what the scheduler "recommends"; setting
/// `probeFailure` makes the first probe throw so the cycle's error path can
/// be tested.
class RecordingAutoSelection extends ProxySelection {
  RecordingAutoSelection({
    required MihomoAPI api,
    required SmartSelector selector,
    this.best,
    this.probeFailure,
  }) : super(api: api, selector: selector);

  final String? best;
  final Object? probeFailure;
  final List<String> probes = <String>[];
  int loads = 0;
  Iterable<String>? lastCandidates;
  String? lastCurrent;

  @override
  Future<void> load() async {
    loads++;
    await super.load();
  }

  @override
  Future<void> probeByName(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = kProbeTimeoutMs,
  }) async {
    probes.add(name);
    if (probeFailure != null) throw probeFailure!;
  }

  @override
  Future<String?> bestProxy({
    Iterable<String>? candidates,
    String? current,
  }) async {
    lastCandidates = candidates;
    lastCurrent = current;
    return best;
  }
}

Widget _app(ProxySelection selection, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SchedulerDashboard(selection: selection)),
  );
}

Future<ProxySelection> _loaded(
  FakeMihomoApi api,
  FakeScheduler scheduler,
) async {
  final selection = ProxySelection(
    api: api,
    selector: SmartSelector(scheduler: scheduler),
  );
  await selection.load();
  return selection;
}

Future<RecordingAutoSelection> _loadedRecording(
  FakeMihomoApi api,
  FakeScheduler scheduler, {
  String? best,
  Object? probeFailure,
}) async {
  final selection = RecordingAutoSelection(
    api: api,
    selector: SmartSelector(scheduler: scheduler),
    best: best,
    probeFailure: probeFailure,
  );
  await selection.load();
  return selection;
}

/// A generous surface keeps all rank rows off the scroll overflow during
/// assertions; restored after each test.
Future<void> _prepare(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets(
    'ranking list shows every field and highlights the lowest score',
    (tester) async {
      await _prepare(tester);
      final scheduler = FakeScheduler(
        rows: <NodeRank>[
          const NodeRank(
            proxy: 'A',
            ewma: 120.5,
            jitter: 5.2,
            score: 40.0,
            samples: 4,
            failures: 1,
            ageMs: 2500,
            available: true,
          ),
          const NodeRank(
            proxy: 'B',
            ewma: 80.0,
            jitter: 1.5,
            score: 20.0,
            samples: 6,
            failures: 0,
            ageMs: 300,
            available: true,
          ),
        ],
      );
      final selection = await _loaded(FakeMihomoApi(), scheduler);
      await tester.pumpWidget(_app(selection));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scheduler-rank-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduler-rank-B')), findsOneWidget);
      expect(find.textContaining('EWMA 120.5'), findsOneWidget);
      expect(find.textContaining('Jitter 5.2'), findsOneWidget);
      expect(find.textContaining('Score 40.0'), findsOneWidget);
      expect(find.textContaining('Samples 4'), findsOneWidget);
      expect(find.textContaining('Fails 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('scheduler-rank-A')),
          matching: find.textContaining('Available Yes'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Age 2.5s'), findsOneWidget);
      // Second row's fields are present too.
      expect(find.textContaining('EWMA 80.0'), findsOneWidget);
      expect(find.textContaining('Score 20.0'), findsOneWidget);
      expect(find.textContaining('Age 300ms'), findsOneWidget);

      // B has the lowest score (20 < 40) and is the only highlighted row.
      expect(find.byKey(const ValueKey('scheduler-lowest-B')), findsOneWidget);
      expect(find.text('Lowest'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('scheduler-rank-B')),
          matching: find.text('Lowest'),
        ),
        findsOneWidget,
      );

      // Group picker exposes only Selectors, not the URLTest pool.
      final dropdown = tester.widget<DropdownButton<GroupItem>>(
        find.byKey(const ValueKey('scheduler-group')),
      );
      expect(dropdown.items, hasLength(1));
      expect(dropdown.items!.first.value!.name, 'MAIN');
    },
  );

  testWidgets('backend badge follows rustActive in both locales', (
    tester,
  ) async {
    await _prepare(tester);
    final rustSelection = await _loaded(
      FakeMihomoApi(),
      FakeScheduler(rust: true),
    );
    await tester.pumpWidget(_app(rustSelection));
    await tester.pumpAndSettle();
    expect(find.text('Rust core'), findsOneWidget);
    expect(find.text('Dart fallback'), findsNothing);

    final dartSelection = await _loaded(
      FakeMihomoApi(),
      FakeScheduler(rust: false),
    );
    await tester.pumpWidget(_app(dartSelection, locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('Dart 回退'), findsOneWidget);
    expect(find.text('Rust 核心'), findsNothing);
  });

  testWidgets('auto select commits through select and adopt', (tester) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final scheduler = FakeScheduler(rust: false, bestProxy: 'B');
    final selector = SmartSelector(scheduler: scheduler);
    final selection = ProxySelection(api: api, selector: selector);
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    expect(find.textContaining('Current: A'), findsOneWidget);
    expect(find.textContaining('Recommended: -'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scheduler-auto-select')));
    await tester.pumpAndSettle();

    expect(api.selectCalls, <(String, String)>[('MAIN', 'B')]);
    expect(selector.current, 'B');
    expect(scheduler.lastCandidates!.toSet(), <String>{'A', 'B', 'C'});
    expect(scheduler.lastCurrent, 'A');
    // The commit now refreshes `now` from the controller.
    expect(find.textContaining('Current: B'), findsOneWidget);
    expect(find.textContaining('Recommended: B'), findsOneWidget);
    expect(find.text('Selected B in MAIN'), findsOneWidget);
  });

  testWidgets('auto select hints when the best node is already current', (
    tester,
  ) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final scheduler = FakeScheduler(bestProxy: 'A');
    final selector = SmartSelector(scheduler: scheduler);
    final selection = ProxySelection(api: api, selector: selector);
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scheduler-auto-select')));
    await tester.pumpAndSettle();

    expect(api.selectCalls, isEmpty);
    expect(selector.current, isNull);
    expect(find.text('Already on the best node: A'), findsOneWidget);
  });

  testWidgets('auto schedule switch exists and is off without requests', (
    tester,
  ) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final idle = await _loadedRecording(api, FakeScheduler(bestProxy: 'B'));
    await tester.pumpWidget(_app(idle));
    await tester.pumpAndSettle();

    final toggle = tester.widget<Switch>(
      find.byKey(const ValueKey('scheduler-auto-schedule-switch')),
    );
    expect(toggle.value, isFalse);
    expect(find.byKey(const ValueKey('scheduler-backend')), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-auto-select')), findsOneWidget);
    // Plain-language legend at the top of the dashboard.
    expect(find.textContaining('lower score is better'), findsOneWidget);

    expect(idle.probes, isEmpty);
    expect(api.selectCalls, isEmpty);
    // Advancing past a whole period proves no periodic timer was started.
    await tester.pump(kAutoSchedulePeriod + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(idle.probes, isEmpty);
    expect(api.selectCalls, isEmpty);
  });

  testWidgets('turning auto schedule on fires a cycle, off stops it', (
    tester,
  ) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'B'),
      best: 'B',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('scheduler-auto-schedule-switch'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);

    // One period elapses -> exactly one automated cycle runs.
    await tester.pump(kAutoSchedulePeriod);
    await tester.pumpAndSettle();
    expect(selection.probes, <String>['A', 'B', 'C']);
    expect(api.selectCalls, <(String, String)>[('MAIN', 'B')]);
    final afterFirst = List<String>.from(selection.probes);

    // Toggling off cancels the timer; another period is silent.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await tester.pump(kAutoSchedulePeriod);
    await tester.pumpAndSettle();
    expect(selection.probes, afterFirst);
  });

  testWidgets('runAutoCycle probes, recommends with current, commits and '
      'refreshes', (tester) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final scheduler = FakeScheduler(bestProxy: 'B');
    final selection = await _loadedRecording(api, scheduler, best: 'B');
    final selector = selection.selector;
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    final loadsBefore = selection.loads;
    final ranksBefore = scheduler.rankCalls;

    final state = tester.state<SchedulerDashboardState>(
      find.byType(SchedulerDashboard),
    );
    await state.runAutoCycle();
    await tester.pumpAndSettle();

    expect(selection.probes, <String>['A', 'B', 'C']);
    expect(selection.lastCurrent, 'A');
    expect(selection.lastCandidates!.toSet(), <String>{'A', 'B', 'C'});
    expect(api.selectCalls, <(String, String)>[('MAIN', 'B')]);
    expect(selector.current, 'B');
    // Both the proxy snapshot and the ranking were reloaded.
    expect(selection.loads, loadsBefore + 1);
    expect(scheduler.rankCalls, greaterThan(ranksBefore));
    expect(find.textContaining('Current: B'), findsOneWidget);
    expect(find.textContaining('Recommended: B'), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-auto-note')), findsOneWidget);
    expect(
      find.textContaining('Auto-switched to B (auto schedule)'),
      findsOneWidget,
    );
  });

  testWidgets('runAutoCycle does not PUT when best equals the current node', (
    tester,
  ) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'A'),
      best: 'A',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    final state = tester.state<SchedulerDashboardState>(
      find.byType(SchedulerDashboard),
    );
    await state.runAutoCycle();
    await tester.pumpAndSettle();

    expect(selection.probes, <String>['A', 'B', 'C']);
    expect(api.selectCalls, isEmpty);
    expect(selection.selector.current, isNull);
    expect(find.textContaining('no switch needed'), findsOneWidget);
    expect(find.textContaining('Auto-switched'), findsNothing);
  });

  testWidgets('runAutoCycle does not PUT when no Selector contains best', (
    tester,
  ) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'X'),
      best: 'X',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    final state = tester.state<SchedulerDashboardState>(
      find.byType(SchedulerDashboard),
    );
    await state.runAutoCycle();
    await tester.pumpAndSettle();

    expect(api.selectCalls, isEmpty);
    expect(selection.selector.current, isNull);
    expect(find.textContaining('no manual group contains X'), findsOneWidget);
  });

  testWidgets('runAutoCycle reports probe failures without crashing', (
    tester,
  ) async {
    await _prepare(tester);
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'B'),
      best: 'B',
      probeFailure: StateError('probe boom'),
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    final state = tester.state<SchedulerDashboardState>(
      find.byType(SchedulerDashboard),
    );
    await state.runAutoCycle();
    await tester.pumpAndSettle();

    expect(api.selectCalls, isEmpty);
    expect(selection.selector.current, isNull);
    expect(find.textContaining('Auto schedule failed'), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-auto-note')), findsOneWidget);
  });
}
