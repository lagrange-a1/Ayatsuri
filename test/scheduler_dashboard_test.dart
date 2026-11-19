// test/scheduler_dashboard_test.dart
//
// Widget tests for the user-visible scheduling dashboard: rank fields,
// backend badge copy, the auto-select commit path (put + adopt), and the
// opt-in background auto-schedule cycle.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/info/scheduler_dashboard.dart';
import 'package:ayatsuri/proxies/address_filter.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';
import 'package:ayatsuri/proxies/proxy_service.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/proxies/smart_selector.dart';
import 'package:ayatsuri/settings/boot_policy.dart';

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
  Future<Response<dynamic>> getProxies() => Future<Response<dynamic>>.value(
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
  Future<Response<dynamic>> getGroups() => Future<Response<dynamic>>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{'proxies': groups},
    ),
  );

  @override
  Future<Response<dynamic>> selectProxy(
    String name, {
    required String proxyName,
  }) {
    selectCalls.add((name, proxyName));
    for (final group in groups) {
      if (group['name'] == name) group['now'] = proxyName;
    }
    return Future<Response<dynamic>>.value(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(),
        data: <String, dynamic>{},
      ),
    );
  }
}

/// Controller fake whose delay endpoint actually returns numbers, so the real
/// [ProxySelection.probeByName] path records samples into the scheduler. This
/// is what turns the dashboard's empty state into a populated ranking.
class DelayProbeApi extends FakeMihomoApi {
  DelayProbeApi(this.delays);

  final Map<String, int> delays;
  final List<String> probed = <String>[];

  @override
  Future<Response<dynamic>> testProxyDelay(
    String name, {
    required String url,
    int timeout = 5000,
    String? expected,
  }) {
    probed.add(name);
    return Future<Response<dynamic>>.value(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/proxies/$name/delay'),
        data: <String, dynamic>{'delay': delays[name] ?? 100},
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
    if (probeFailure != null) throw StateError(probeFailure.toString());
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

/// Scheduler whose active flag follows the static preference, so a widget
/// test can observe the chip rebuilding when the preference changes without
/// needing a real native library.
class PreferenceAwareScheduler extends SchedulerWrapper {
  @override
  bool get rustActive =>
      SchedulerWrapper.backendPreference == RoutingBackend.rustFirst;

  @override
  Future<List<NodeRank>> rank(Iterable<String> candidates) async =>
      const <NodeRank>[];
}

/// A Selector that contains a hidden 127/8 node, so the auto-cycle reaches
/// the commit boundary instead of stopping at `_targetFor`.
class LoopbackGroupApi extends FakeMihomoApi {
  @override
  Future<Response<dynamic>> getGroups() => Future<Response<dynamic>>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <dynamic>[
          <String, dynamic>{
            'name': 'go',
            'type': 'Selector',
            'all': <String>['A', '127.0.0.53'],
            'now': 'A',
          },
        ],
      },
    ),
  );
}

/// 60-member Selector group: `_probeGroup` must split it into two 50-node
/// batches instead of awaiting each node serially (P0-3).
class BigGroupApi extends FakeMihomoApi {
  BigGroupApi();

  static final List<String> names = List<String>.generate(
    60,
    (i) => 'N${i.toString().padLeft(2, '0')}',
  );

  @override
  Future<Response<dynamic>> getGroups() => Future<Response<dynamic>>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <dynamic>[
          <String, dynamic>{
            'name': 'BIG',
            'type': 'Selector',
            'all': names,
            'now': names.first,
          },
        ],
      },
    ),
  );
}

/// Records every group probe; optionally fails one node (first batch) to
/// prove the rest of the group is still measured.
class BigGroupSelection extends ProxySelection {
  BigGroupSelection({
    required MihomoAPI api,
    required SmartSelector selector,
    this.failing,
  }) : super(api: api, selector: selector);

  final String? failing;
  final List<String> probes = <String>[];

  @override
  Future<void> probeByName(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = kProbeTimeoutMs,
  }) async {
    probes.add(name);
    if (name == failing) throw StateError('probe boom: $name');
  }
}

/// Holds each probe behind a gate so a test can count how many probes were
/// *started* before any completed: batching starts 50 at once, serial probing
/// starts only one.
class GatedGroupSelection extends ProxySelection {
  GatedGroupSelection({required MihomoAPI api, required SmartSelector selector})
    : super(api: api, selector: selector);

  final List<String> probes = <String>[];
  final List<Completer<void>> gates = <Completer<void>>[];

  @override
  Future<void> probeByName(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = kProbeTimeoutMs,
  }) async {
    probes.add(name);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
  }

  void release() {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
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
  // Rust backend state is static; start every test from a known lifecycle.
  // The backend-preference chip switches also write SharedPreferences; give
  // the legacy plugin a deterministic in-memory store so tests never depend
  // on platform-channel availability.
  setUp(() {
    SchedulerWrapper.resetForTests();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // The boot policy lives in a global singleton; every test starts from the
    // manual-only default so startup behaviour is never inherited.
    BootPolicyController.instance.resetForTests();
  });

  testWidgets('boot policy probe runs exactly one full-group probe on mount', (
    tester,
  ) async {
    await _prepare(tester);
    BootPolicyController.instance.notifier.value = ProbeBootstrap.probe;
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'B'),
      best: 'B',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    // One full pass over the group: each member probed exactly once. The
    // startup probe only builds samples — it never commits a node.
    expect(selection.probes, <String>['A', 'B', 'C']);
    expect(api.selectCalls, isEmpty);
    // `probe` does not seed the periodic loop; the switch stays off.
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('scheduler-auto-schedule-switch')),
          )
          .value,
      isFalse,
    );

    // A whole period later the probe has not run again.
    await tester.pump(kAutoSchedulePeriod + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(selection.probes, <String>['A', 'B', 'C']);
    expect(api.selectCalls, isEmpty);
  });

  testWidgets('boot policy off performs no automatic probe or schedule', (
    tester,
  ) async {
    await _prepare(tester);
    BootPolicyController.instance.notifier.value = ProbeBootstrap.off;
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'B'),
      best: 'B',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    expect(selection.probes, isEmpty);
    expect(api.selectCalls, isEmpty);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('scheduler-auto-schedule-switch')),
          )
          .value,
      isFalse,
    );
    await tester.pump(kAutoSchedulePeriod + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(selection.probes, isEmpty);
    expect(api.selectCalls, isEmpty);
  });

  testWidgets('boot policy probeAndSchedule probes once and seeds the timer', (
    tester,
  ) async {
    await _prepare(tester);
    BootPolicyController.instance.notifier.value =
        ProbeBootstrap.probeAndSchedule;
    final api = FakeMihomoApi();
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'B'),
      best: 'B',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    // Same one-shot startup probe as `probe`, switch on from the policy, but
    // still no commit until a scheduled cycle actually runs.
    expect(selection.probes, <String>['A', 'B', 'C']);
    expect(api.selectCalls, isEmpty);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('scheduler-auto-schedule-switch')),
          )
          .value,
      isTrue,
    );

    await tester.pump(kAutoSchedulePeriod);
    await tester.pumpAndSettle();
    expect(selection.probes, <String>['A', 'B', 'C', 'A', 'B', 'C']);
    expect(api.selectCalls, <(String, String)>[('MAIN', 'B')]);
  });

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
      expect(find.text('Best'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('scheduler-rank-B')),
          matching: find.text('Best'),
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

  testWidgets('backend badge reports real Rust status, not a bare Dart claim', (
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
    expect(find.textContaining('Rust unavailable'), findsNothing);

    // No load attempted yet: the badge shows the real initializing status
    // instead of an unconditional "Dart fallback".
    final dartSelection = await _loaded(
      FakeMihomoApi(),
      FakeScheduler(rust: false),
    );
    await tester.pumpWidget(_app(dartSelection, locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('Rust 后端初始化中…'), findsOneWidget);
    expect(find.text('Dart 回退'), findsNothing);
  });

  testWidgets('backend badge surfaces the native load failure reason', (
    tester,
  ) async {
    await _prepare(tester);
    final wrapper = SchedulerWrapper();
    // Drive the real load path: on this host the dylib is absent, so the
    // public rustStatus flips to unavailable with a readable reason.
    await wrapper.observe('A', 100);
    expect(SchedulerWrapper.rustStatus, RustBackendStatus.unavailable);

    final selection = ProxySelection(
      api: FakeMihomoApi(),
      selector: SmartSelector(scheduler: wrapper),
    );
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    expect(find.textContaining('Rust unavailable:'), findsOneWidget);
    expect(find.text('Rust core'), findsNothing);

    await tester.pumpWidget(_app(selection, locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rust 不可用：'), findsOneWidget);
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
    // Technical legend describing the sort key and metric units.
    expect(
      find.textContaining('Sort key: Score (ascending, lower first)'),
      findsOneWidget,
    );
    expect(find.textContaining('EWMA/Jitter in ms'), findsOneWidget);

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

  testWidgets('empty state explains the gap and offers a group probe', (
    tester,
  ) async {
    await _prepare(tester);
    final selection = await _loaded(
      FakeMihomoApi(),
      FakeScheduler(rows: const <NodeRank>[]),
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('scheduler-empty')), findsOneWidget);
    expect(find.text('No scheduling samples yet'), findsOneWidget);
    expect(
      find.text('Probe the current group to build a ranking'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('scheduler-group-probe')), findsOneWidget);
    expect(find.text('Probe current group'), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-rank-A')), findsNothing);

    // Bilingual copy: the zh variant still exposes the same probe action.
    await tester.pumpWidget(_app(selection, locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('暂无调度样本'), findsOneWidget);
    expect(find.text('测速当前组'), findsOneWidget);
  });

  testWidgets('probing the current group produces samples and ranks', (
    tester,
  ) async {
    await _prepare(tester);
    final api = DelayProbeApi(<String, int>{'A': 90, 'B': 120, 'C': 60});
    final wrapper = SchedulerWrapper();
    final selection = ProxySelection(
      api: api,
      selector: SmartSelector(scheduler: wrapper),
    );
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    // Genuinely empty before the tap — no auto-probe on mount.
    expect(find.byKey(const ValueKey('scheduler-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scheduler-group-probe')));
    await tester.pumpAndSettle();

    expect(api.probed.toSet(), <String>{'A', 'B', 'C'});
    expect(find.byKey(const ValueKey('scheduler-empty')), findsNothing);
    expect(find.byKey(const ValueKey('scheduler-rank-A')), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-rank-B')), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-rank-C')), findsOneWidget);
    // C has the smallest delay, so it is the highlighted lowest-score row.
    expect(find.byKey(const ValueKey('scheduler-lowest-C')), findsOneWidget);
    // Probing only builds samples here; it must not commit any node.
    expect(api.selectCalls, isEmpty);
  });

  testWidgets('backend chip updates immediately when preference switches', (
    tester,
  ) async {
    await _prepare(tester);
    SchedulerWrapper.resetForTests();
    final api = FakeMihomoApi();
    final scheduler = PreferenceAwareScheduler();
    final selection = ProxySelection(
      api: api,
      selector: SmartSelector(scheduler: scheduler),
    );
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    String chipText() => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(const ValueKey('scheduler-backend')),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;

    expect(chipText(), 'Rust core');

    // No navigation and no manual setState on this page: only the public
    // notifier can make this chip rebuild (P0-2).
    await SchedulerWrapper.setBackendPreference(RoutingBackend.forceDart);
    await tester.pump();
    expect(chipText(), isNot('Rust core'));
    expect(chipText(), isNotEmpty);

    await SchedulerWrapper.setBackendPreference(RoutingBackend.rustFirst);
    await tester.pump();
    expect(chipText(), 'Rust core');
    SchedulerWrapper.resetForTests();
  });

  testWidgets('group probe starts a full 50-node batch concurrently', (
    tester,
  ) async {
    await _prepare(tester);
    SchedulerWrapper.resetForTests();
    final api = BigGroupApi();
    final selection = GatedGroupSelection(
      api: api,
      selector: SmartSelector(scheduler: FakeScheduler()),
    );
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scheduler-group-probe')));
    await tester.pump();

    // 50 probes were started before the first gate completed. A serial
    // for-loop would have started exactly one by this point (P0-3).
    expect(selection.probes, hasLength(50));
    selection.release();
    await tester.pump();
    expect(selection.probes, hasLength(60));
    selection.release();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scheduler-group-probe')), findsOneWidget);
  });

  testWidgets('one failing node does not abort the group probe', (
    tester,
  ) async {
    await _prepare(tester);
    SchedulerWrapper.resetForTests();
    final api = BigGroupApi();
    final selection = BigGroupSelection(
      api: api,
      selector: SmartSelector(scheduler: FakeScheduler()),
      failing: BigGroupApi.names.first, // in batch 1
    );
    await selection.load();
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scheduler-group-probe')));
    await tester.pumpAndSettle();

    // The old serial loop stopped on the first throw; now every node in
    // both batches is measured (P0-3).
    expect(selection.probes, hasLength(60));
    expect(selection.probes, contains(BigGroupApi.names.last));
    expect(find.byKey(const ValueKey('scheduler-empty')), findsOneWidget);
  });

  testWidgets('auto cycle never commits a loopback-filtered node', (
    tester,
  ) async {
    await _prepare(tester);
    AddressFilterController.resetForTests();
    addTearDown(() => AddressFilterController.resetForTests());
    await AddressFilterController.setEnabled(<AddressPreset>{
      AddressPreset.loopback,
    });
    final api = LoopbackGroupApi();
    // The fake scheduler deliberately recommends a hidden node: even a bad
    // upstream suggestion must be stopped at the commit boundary.
    final selection = await _loadedRecording(
      api,
      FakeScheduler(bestProxy: 'A'),
      best: '127.0.0.53',
    );
    await tester.pumpWidget(_app(selection));
    await tester.pumpAndSettle();
    final state = tester.state<SchedulerDashboardState>(
      find.byType(SchedulerDashboard),
    );
    await state.runAutoCycle();
    await tester.pumpAndSettle();

    expect(api.selectCalls, isEmpty);
    expect(find.textContaining('Auto schedule failed'), findsOneWidget);
  });
}
