/*
 * Widget tests for the standalone FlClash-style ProxyListPage.
 *
 * A fake controller feeds fixed groups/nodes; a recording ProxySelection
 * lets the tests assert *which* model method a tap reached (select vs
 * selectAny) without depending on HTTP behaviour.
 */

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/info/scheduler_dashboard.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';
import 'package:ayatsuri/proxies/proxy_list_page.dart';
import 'package:ayatsuri/proxies/proxy_service.dart';

class FakeProxyApi extends MihomoAPI {
  FakeProxyApi() : super(baseUrl: 'http://localhost:9091');

  /// When true, `selectProxy` fails with an authoritative 404 so the page
  /// must surface a readable snackbar.
  bool failSelect = false;

  final Map<String, Map<String, dynamic>> _proxies = {
    'HK 2': {'name': 'HK 2', 'type': 'Direct', 'alive': true, 'delay': 120},
    'CN 1': {'name': 'CN 1', 'type': 'Direct', 'alive': true, 'delay': 800},
    'US 3': {'name': 'US 3', 'type': 'Direct', 'alive': true, 'delay': 60},
    'JP 4': {'name': 'JP 4', 'type': 'Direct', 'alive': true, 'delay': 300},
    // Unreachable (alive == false, no delay) on purpose: it must still be
    // listed, never hidden.
    'SG 5': {'name': 'SG 5', 'type': 'Direct', 'alive': false},
  };

  final List<Map<String, dynamic>> _groups = [
    {
      'name': 'PROXY',
      'type': 'Selector',
      'all': ['HK 2', 'CN 1', 'US 3'],
      'now': 'HK 2',
    },
    {
      'name': 'AUTO-POOL',
      'type': 'URLTest',
      'all': ['JP 4', 'SG 5'],
      'now': 'JP 4',
    },
  ];

  @override
  Future<Response> getProxies() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{'proxies': _proxies},
    ),
  );

  @override
  Future<Response> getGroups() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{'proxies': _groups},
    ),
  );

  @override
  Future<Response> selectProxy(String name, {required String proxyName}) {
    if (failSelect) {
      return Future<Response>.error(
        DioException(
          requestOptions: RequestOptions(path: '/proxies/$name'),
          type: DioExceptionType.badResponse,
          response: Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(),
            statusCode: 404,
          ),
          message: 'not found',
        ),
      );
    }
    return Future<Response>.value(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(),
        data: <String, dynamic>{},
      ),
    );
  }
}

/// A ProxySelection that records which selection method a tap reached and
/// returns a deterministic best-proxy suggestion for the badge test. It also
/// records the `current` anchor and how many times bestProxy was asked.
class RecordingProxySelection extends ProxySelection {
  RecordingProxySelection({required MihomoAPI api, this.best})
    : super(api: api);

  final String? best;
  final List<(String, String)> selects = <(String, String)>[];
  final List<(String, String)> selectAnys = <(String, String)>[];
  final List<String?> currentCalls = <String?>[];
  int bestCalls = 0;

  @override
  Future<String?> bestProxy({
    Iterable<String>? candidates,
    String? current,
  }) async {
    currentCalls.add(current);
    bestCalls++;
    return best;
  }

  @override
  Future<void> select(String groupName, String proxyName) async {
    selects.add((groupName, proxyName));
    await super.select(groupName, proxyName);
  }

  @override
  Future<void> selectAny(String group, String proxyName) async {
    selectAnys.add((group, proxyName));
    await super.selectAny(group, proxyName);
  }
}

/// A ProxySelection whose `bestProxy` answers are controlled by the test, so
/// an old group's answer can be completed *after* a newer group's answer to
/// exercise the generation guard. Also records the `current` anchor.
class RaceProxySelection extends ProxySelection {
  RaceProxySelection({required MihomoAPI api}) : super(api: api);

  final List<Completer<String?>> _answers = <Completer<String?>>[];
  final List<Iterable<String>?> candidateCalls = <Iterable<String>?>[];
  final List<String?> currentCalls = <String?>[];

  @override
  Future<String?> bestProxy({Iterable<String>? candidates, String? current}) {
    candidateCalls.add(candidates);
    currentCalls.add(current);
    final completer = Completer<String?>();
    _answers.add(completer);
    return completer.future;
  }

  void answer(int call, String? node) => _answers[call].complete(node);
}

/// Records single-node probe taps without issuing HTTP: the page must call
/// probeByName for the tapped node and then recompute the recommendation.
class ProbeRecordingSelection extends RecordingProxySelection {
  ProbeRecordingSelection({required MihomoAPI api, String? best})
    : super(api: api, best: best);

  final List<String> probed = <String>[];

  @override
  Future<void> probeByName(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = kProbeTimeoutMs,
  }) async {
    probed.add(name);
  }
}

/// Simulates a controller whose `now` is briefly unknown after load: the
/// group's `now` is hidden until the third load, so the page's bounded poll
/// must resolve it instead of leaving the recommendation empty.
class LateNowSelection extends RecordingProxySelection {
  LateNowSelection({required MihomoAPI api}) : super(api: api);

  int loads = 0;

  @override
  Future<void> load() async {
    loads++;
    await super.load();
  }

  @override
  List<GroupItem> get allGroups {
    final groups = super.allGroups;
    if (loads < 3) {
      return groups
          .map((g) => GroupItem(name: g.name, type: g.type, all: g.all))
          .toList();
    }
    return groups;
  }
}

/// A controller whose `now` is never published: the bounded poll must exhaust
/// and surface a visible "unavailable" status instead of failing silently.
class NeverNowSelection extends RecordingProxySelection {
  NeverNowSelection({required MihomoAPI api}) : super(api: api);

  int loads = 0;

  @override
  Future<void> load() async {
    loads++;
    await super.load();
  }

  @override
  List<GroupItem> get allGroups => super.allGroups
      .map((g) => GroupItem(name: g.name, type: g.type, all: g.all))
      .toList();
}

/// bestProxy that always throws: a failure must not clear the default or
/// stall the list.
class ThrowingBestSelection extends ProxySelection {
  ThrowingBestSelection({required MihomoAPI api}) : super(api: api);

  @override
  Future<String?> bestProxy({Iterable<String>? candidates, String? current}) {
    throw StateError('best boom');
  }
}

/// Controller with measured, blocked (0), timeout (-1) and unprobed (null)
/// nodes in one group, to exercise latency ordering and the hide toggle.
class DelayEdgeApi extends MihomoAPI {
  DelayEdgeApi() : super(baseUrl: 'http://localhost:9091');

  @override
  Future<Response> getProxies() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <String, dynamic>{
          'A-fast': {
            'name': 'A-fast',
            'type': 'Direct',
            'alive': true,
            'delay': 100,
          },
          'B-blocked': {
            'name': 'B-blocked',
            'type': 'Direct',
            'alive': true,
            'delay': 0,
          },
          'C-timeout': {
            'name': 'C-timeout',
            'type': 'Direct',
            'alive': true,
            'delay': -1,
          },
          'D-unknown': {'name': 'D-unknown', 'type': 'Direct', 'alive': true},
          'E-slow': {
            'name': 'E-slow',
            'type': 'Direct',
            'alive': true,
            'delay': 900,
          },
        },
      },
    ),
  );

  @override
  Future<Response> getGroups() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <dynamic>[
          <String, dynamic>{
            'name': 'EDGE',
            'type': 'Selector',
            'all': <String>[
              'A-fast',
              'B-blocked',
              'C-timeout',
              'D-unknown',
              'E-slow',
            ],
            'now': 'A-fast',
          },
        ],
      },
    ),
  );
}

/// Probe taps are held behind completers so a test can observe the ping
/// progress state before releasing the batch.
class GatedProbeSelection extends ProbeRecordingSelection {
  GatedProbeSelection({required super.api, super.best});

  final List<Completer<void>> gates = <Completer<void>>[];

  @override
  Future<void> probeByName(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = kProbeTimeoutMs,
  }) async {
    probed.add(name);
    final completer = Completer<void>();
    gates.add(completer);
    await completer.future;
  }

  void release() {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

/// A 60-member Selector group so the whole-group ping has two 50-node
/// batches. A failure in the first batch must not skip the second (P0-1).
class BatchProbeApi extends MihomoAPI {
  BatchProbeApi() : super(baseUrl: 'http://localhost:9091');

  static final List<String> names = List<String>.generate(
    60,
    (i) => 'N${i.toString().padLeft(2, '0')}',
  );

  @override
  Future<Response> getProxies() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <String, dynamic>{
          for (final name in names)
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

/// Fails one node's probe but still records every call, so a test can assert
/// the rest of the group (including later batches) was measured.
class BatchFailingProbeSelection extends ProbeRecordingSelection {
  BatchFailingProbeSelection({required MihomoAPI api, required this.failing})
    : super(api: api);

  final String failing;

  @override
  Future<void> probeByName(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = kProbeTimeoutMs,
  }) async {
    probed.add(name);
    if (name == failing) throw StateError('probe boom: $name');
  }
}

/// Vertical position of a node row, for asserting display order.
double _topOf(WidgetTester tester, String name) =>
    tester.getTopLeft(find.byKey(ValueKey('proxy-node-$name'))).dy;

Future<RecordingProxySelection> _pumpPage(
  WidgetTester tester, {
  String? best,
  bool failSelect = false,
}) async {
  final api = FakeProxyApi()..failSelect = failSelect;
  final selection = RecordingProxySelection(api: api, best: best);
  await _pumpWith(tester, api: api, selection: selection);
  return selection;
}

Future<void> _pumpWith(
  WidgetTester tester, {
  required MihomoAPI api,
  required ProxySelection selection,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ProxyListPage(api: api, selection: selection),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Open the sort popup; its menu items are only mounted while it is open.
Future<void> _openSortMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('proxy-sort-popup')));
  await tester.pumpAndSettle();
}

void main() {
  // MihomoAPI's constructor reads dotenv; install an in-memory env the same
  // way the other test files do (`.env` is no longer a bundled asset).
  dotenv.loadFromString(envString: 'host=localhost\nport=9091\nsecret=***\n');

  testWidgets('switching group shows all of that group nodes', (tester) async {
    await _pumpPage(tester);

    // Initial group is the Selector "PROXY": all three members are visible.
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsOneWidget);
    expect(find.text('HK 2'), findsOneWidget);
    expect(find.text('CN 1'), findsOneWidget);
    expect(find.text('US 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-node-JP 4')), findsNothing);

    // Switch to the automatic group; its members replace the previous ones.
    await tester.tap(find.byKey(const ValueKey('proxy-group-AUTO-POOL')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('proxy-node-JP 4')), findsOneWidget);
    expect(find.text('JP 4'), findsOneWidget);
    // Unreachable SG 5 is still listed, never hidden.
    expect(find.text('SG 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsNothing);
    expect(find.text('HK 2'), findsNothing);
  });

  testWidgets('automatic group shows an AUTO badge', (tester) async {
    await _pumpPage(tester);
    expect(
      find.byKey(const ValueKey('proxy-auto-badge-AUTO-POOL')),
      findsOneWidget,
    );
    expect(find.text('AUTO'), findsOneWidget);
    // The Selector group has no automatic badge.
    expect(find.byKey(const ValueKey('proxy-auto-badge-PROXY')), findsNothing);
  });

  testWidgets('dev mode unlocks selectAny on automatic group rows', (
    tester,
  ) async {
    final selection = await _pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('proxy-group-AUTO-POOL')));
    await tester.pumpAndSettle();

    // Without dev mode, automatic rows are inert.
    await tester.tap(find.byKey(const ValueKey('proxy-node-JP 4')));
    await tester.pumpAndSettle();
    expect(selection.selects, isEmpty);
    expect(selection.selectAnys, isEmpty);

    // Enable dev mode: the same row now reaches selectAny, never select.
    await tester.tap(find.byKey(const ValueKey('proxy-dev-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('proxy-node-JP 4')));
    await tester.pumpAndSettle();

    expect(selection.selectAnys, contains(('AUTO-POOL', 'JP 4')));
    expect(selection.selects, isEmpty);
  });

  testWidgets('selector group rows call select', (tester) async {
    final selection = await _pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('proxy-node-CN 1')));
    await tester.pumpAndSettle();

    expect(selection.selects, contains(('PROXY', 'CN 1')));
    expect(selection.selectAnys, isEmpty);
  });

  testWidgets('bestProxy suggestion gets a recommendation badge', (
    tester,
  ) async {
    final selection = await _pumpPage(tester, best: 'CN 1');
    expect(
      find.byKey(const ValueKey('proxy-recommended-CN 1')),
      findsOneWidget,
    );
    expect(find.text('Recommended'), findsOneWidget);
    // The current node (HK 2) never receives the recommendation badge.
    expect(find.byKey(const ValueKey('proxy-recommended-HK 2')), findsNothing);
    // The current node is passed as the bestProxy anchor (RC-2 fix).
    expect(selection.currentCalls, contains('HK 2'));
  });

  testWidgets('selection failure shows a readable snackbar', (tester) async {
    await _pumpPage(tester, failSelect: true);

    await tester.tap(find.byKey(const ValueKey('proxy-node-HK 2')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('proxy-select-error')), findsOneWidget);
    expect(find.textContaining('Selection failed'), findsOneWidget);

    // Drain the snackbar's dismiss timer so teardown sees no pending timer.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('current node row is highlighted and force label is explained', (
    tester,
  ) async {
    await _pumpPage(tester);

    // The current node's M3 card uses primaryContainer + a primary border
    // and carries the check icon; other nodes stay on the plain card.
    final nowCard = tester.widget<Card>(
      find.byKey(const ValueKey('proxy-node-HK 2')),
    );
    expect(nowCard.color, isNotNull);
    final nowShape = nowCard.shape! as RoundedRectangleBorder;
    expect(nowShape.side.width, greaterThan(0));
    expect(find.byKey(const ValueKey('proxy-current-HK 2')), findsOneWidget);

    final otherCard = tester.widget<Card>(
      find.byKey(const ValueKey('proxy-node-CN 1')),
    );
    expect(otherCard.color, isNull);
    // Non-current cards use the full outlineVariant (no 40% alpha fade).
    final otherShape = otherCard.shape! as RoundedRectangleBorder;
    final scheme = Theme.of(
      tester.element(find.byType(ProxyListPage)),
    ).colorScheme;
    expect(otherShape.side.color, scheme.outlineVariant);
    expect(otherShape.side.color.a, 1.0);
    expect(find.byKey(const ValueKey('proxy-current-CN 1')), findsNothing);
    // Policy tag + tappable delay are present on each card.
    expect(find.byKey(const ValueKey('proxy-type-HK 2')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-delay-HK 2')), findsOneWidget);
    expect(find.text('Force-select auto groups'), findsOneWidget);
    // The auto badge is a plain, always-visible chip: no Tooltip wrapper
    // (N3: remove the duplicate, don't relocate it), and the auto-route
    // constraint is explained in always-visible text (N5: visible before
    // interaction), not inside a hover-only tooltip.
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('proxy-auto-badge-AUTO-POOL')),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
    );
    expect(
      find.text(
        'Some groups are auto-routed by the kernel; manual picks may not apply',
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('proxy-dev-switch')),
        matching: find.byType(Tooltip),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a stale bestProxy answer cannot badge the new group', (
    tester,
  ) async {
    final api = FakeProxyApi();
    final selection = RaceProxySelection(api: api);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProxyListPage(api: api, selection: selection),
        ),
      ),
    );
    // The initial bestProxy answer is held pending, so single pumps are used
    // until the group chips appear (the list itself renders before bestProxy).
    for (
      var i = 0;
      i < 20 &&
          find
              .byKey(const ValueKey('proxy-group-AUTO-POOL'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const ValueKey('proxy-group-AUTO-POOL')), findsOneWidget);

    // Call 0 belongs to the initial PROXY group and is still pending.
    // Switch groups while it is in flight -> call 1 is the newest generation.
    await tester.tap(find.byKey(const ValueKey('proxy-group-AUTO-POOL')));
    await tester.pump();
    await tester.pump();
    expect(selection.candidateCalls, hasLength(2));
    // Both asks were anchored on a real current node.
    expect(selection.currentCalls, contains('HK 2'));
    expect(selection.currentCalls, contains('JP 4'));

    // Newest answer: no recommendation for the current group.
    selection.answer(1, null);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('proxy-recommended-SG 5')), findsNothing);

    // The old group's answer arrives last; it must be ignored entirely.
    selection.answer(0, 'SG 5');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-recommended-SG 5')), findsNothing);
    expect(find.text('SG 5'), findsOneWidget); // row still shown, just no badge
  });

  // ── A: recommendation default / polling / override ────────────────────

  testWidgets('with no probe samples the recommendation defaults to current', (
    tester,
  ) async {
    // A real, un-probed selection: the scheduler has no observations, so it
    // returns null. The badge must degrade to "stay on current", not blank.
    final api = FakeProxyApi();
    final selection = ProxySelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);

    expect(find.byKey(const ValueKey('proxy-current-HK 2')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-recommended-HK 2')), findsNothing);
    expect(find.byKey(const ValueKey('proxy-recommended-CN 1')), findsNothing);
    expect(find.byKey(const ValueKey('proxy-recommended-US 3')), findsNothing);
    // List is rendered, not stuck behind a spinner.
    expect(find.byKey(const ValueKey('proxy-node-CN 1')), findsOneWidget);
  });

  testWidgets('null or throwing bestProxy never clears the default', (
    tester,
  ) async {
    for (final selection in <ProxySelection>[
      RecordingProxySelection(api: FakeProxyApi()), // returns null
      ThrowingBestSelection(api: FakeProxyApi()), // throws
    ]) {
      await _pumpWith(tester, api: FakeProxyApi(), selection: selection);

      expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsOneWidget);
      expect(find.byKey(const ValueKey('proxy-current-HK 2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('proxy-recommended-CN 1')),
        findsNothing,
      );
      // Move off the page so the next selection can be pumped cleanly.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('bounded polling resolves an unknown current node', (
    tester,
  ) async {
    final api = FakeProxyApi();
    final selection = LateNowSelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);

    // The poll reloaded a few times, but stopped well short of any risk of
    // an infinite loop, and the current node was seeded as the default.
    expect(selection.loads, greaterThanOrEqualTo(3));
    expect(selection.loads, lessThanOrEqualTo(20));
    expect(find.byKey(const ValueKey('proxy-current-HK 2')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-recommended-CN 1')), findsNothing);
    expect(selection.currentCalls, contains('HK 2'));
  });

  // ── Tap-to-test probe ──────────────────────────────────────────────────

  testWidgets('tapping the delay label probes only that node and recomputes', (
    tester,
  ) async {
    final api = FakeProxyApi();
    final selection = ProbeRecordingSelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);

    // No startup sweep: nothing probed before the user taps.
    expect(selection.probed, isEmpty);
    final callsBefore = selection.bestCalls;
    expect(callsBefore, greaterThanOrEqualTo(1));

    await tester.tap(find.byKey(const ValueKey('proxy-delay-CN 1')));
    await tester.pumpAndSettle();

    expect(selection.probed, <String>['CN 1']);
    expect(selection.bestCalls, greaterThan(callsBefore));
    expect(selection.currentCalls, contains('HK 2'));
  });

  // ── B: scheduler embedded with a shared ProxySelection ────────────────

  testWidgets('scheduler view is embedded and shares the page selection', (
    tester,
  ) async {
    final api = FakeProxyApi();
    final selection = RecordingProxySelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);

    // Nodes are the default view; the scheduler is switched out.
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('scheduler-auto-schedule-switch')),
      findsNothing,
    );

    // Switch to the schedule view via the M3 segmented button. The segment
    // indicator + freshly mounted dashboard need two short frames before a
    // settle check, otherwise the transition can keep pumpAndSettle chasing.
    await tester.tap(find.text('Schedule'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SchedulerDashboard), findsOneWidget);
    expect(
      find.byKey(const ValueKey('scheduler-auto-schedule-switch')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('scheduler-auto-select')), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-backend')), findsOneWidget);
    // The dashboard reads current from the SAME selection (HK 2), confirming
    // the observation window is shared rather than a fresh instance.
    expect(find.textContaining('HK 2'), findsWidgets);
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsNothing);

    // Auto-schedule switch stays present, off by default and interactive.
    final autoKey = const ValueKey('scheduler-auto-schedule-switch');
    final autoSwitch = tester.widget<Switch>(find.byKey(autoKey));
    expect(autoSwitch.value, isFalse);
    expect(autoSwitch.onChanged, isNotNull);

    // Switch back to nodes (no periodic timer is ever started here).
    await tester.tap(find.text('Nodes'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsOneWidget);
  });

  // ── P0/P1 fixes: tri-state, poll feedback, adopt, guard, ON path, a11y ──

  testWidgets('recommendation status text distinguishes all three states', (
    tester,
  ) async {
    final cases = <(ProxySelection, String)>[
      (RecordingProxySelection(api: FakeProxyApi()), 'No samples'),
      (
        RecordingProxySelection(api: FakeProxyApi(), best: 'HK 2'),
        'Current node is best',
      ),
      (
        RecordingProxySelection(api: FakeProxyApi(), best: 'CN 1'),
        'Switch to CN 1',
      ),
    ];
    for (var i = 0; i < cases.length; i++) {
      final (selection, message) = cases[i];
      await _pumpWith(tester, api: FakeProxyApi(), selection: selection);

      expect(find.byKey(const ValueKey('proxy-best-state')), findsOneWidget);
      expect(find.text('Recommendation'), findsOneWidget);
      expect(find.text(message), findsOneWidget);
      // Only the "switch" state paints a recommendation badge.
      expect(
        find.byKey(const ValueKey('proxy-recommended-CN 1')),
        i == 2 ? findsOneWidget : findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('bounded poll exhaustion shows a visible status, not silence', (
    tester,
  ) async {
    final api = FakeProxyApi();
    final selection = NeverNowSelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);
    // Ensure every delayed poll attempt has fired even if pumpAndSettle
    // stopped early (no frame is scheduled between unsuccessful attempts).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(selection.loads, greaterThan(1));
    expect(selection.loads, lessThanOrEqualTo(1 + 8));
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsOneWidget);
    // The failure is visible as a short status line instead of being silent.
    expect(find.byKey(const ValueKey('proxy-poll-timeout')), findsOneWidget);
    expect(find.textContaining('poll timed out'), findsOneWidget);
  });

  testWidgets('manual node tap adopts the node as the hysteresis anchor', (
    tester,
  ) async {
    final selection = await _pumpPage(tester);
    expect(selection.selector.current, isNull);

    await tester.tap(find.byKey(const ValueKey('proxy-node-CN 1')));
    await tester.pumpAndSettle();

    expect(selection.selects, contains(('PROXY', 'CN 1')));
    expect(selection.selector.current, 'CN 1');
  });

  testWidgets('re-tapping the selected group triggers no recompute', (
    tester,
  ) async {
    final selection = await _pumpPage(tester);
    final callsBefore = selection.bestCalls;
    expect(callsBefore, greaterThanOrEqualTo(1));

    await tester.tap(find.byKey(const ValueKey('proxy-group-PROXY')));
    await tester.pumpAndSettle();

    expect(selection.bestCalls, callsBefore);
    expect(find.byKey(const ValueKey('proxy-node-HK 2')), findsOneWidget);
  });

  testWidgets('auto schedule ON runs periodic cycles and OFF cancels them', (
    tester,
  ) async {
    final api = FakeProxyApi();
    final selection = ProbeRecordingSelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);

    await tester.tap(find.text('Schedule'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SchedulerDashboard), findsOneWidget);

    final autoKey = const ValueKey('scheduler-auto-schedule-switch');
    expect(selection.probed, isEmpty);

    // Opt in: a periodic timer must fire one full cycle after the period.
    await tester.tap(find.byKey(autoKey));
    await tester.pump();
    expect(tester.widget<Switch>(find.byKey(autoKey)).value, isTrue);

    await tester.pump(kAutoSchedulePeriod + const Duration(milliseconds: 1));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(selection.probed.length, greaterThan(0));

    // Opt out: advancing another full period must produce no further probes.
    await tester.tap(find.byKey(autoKey));
    await tester.pump();
    expect(tester.widget<Switch>(find.byKey(autoKey)).value, isFalse);
    final probesAtOff = selection.probed.length;

    await tester.pump(kAutoSchedulePeriod + const Duration(milliseconds: 1));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(selection.probed.length, probesAtOff);
  });

  testWidgets('both view-switch segments have tooltips', (tester) async {
    await _pumpPage(tester);
    expect(
      find.ancestor(of: find.text('Nodes'), matching: find.byType(Tooltip)),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.text('Schedule'), matching: find.byType(Tooltip)),
      findsOneWidget,
    );
  });

  // ── FlClash-style sort / hide / one-click group ping ──────────────────

  testWidgets('sort is a labelled popup with a checkmark on the active mode', (
    tester,
  ) async {
    await _pumpPage(tester);

    // No bare sort chips: the popup label is always visible, the items only
    // exist after the user opens it.
    expect(find.text('Sort'), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-sort-popup')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-sort-name')), findsNothing);

    await _openSortMenu(tester);

    for (final mode in <String>['defaultOrder', 'latency', 'name']) {
      expect(find.byKey(ValueKey('proxy-sort-$mode')), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('proxy-sort-defaultOrder')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('proxy-sort-name')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('proxy-sort-name')));
    await tester.pumpAndSettle();

    expect(_topOf(tester, 'CN 1'), lessThan(_topOf(tester, 'HK 2')));
    // Selecting a mode closes the popup.
    expect(find.byKey(const ValueKey('proxy-sort-name')), findsNothing);
  });

  testWidgets('sort default preserves controller config order', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPage(tester);

    // PROXY group config order is HK 2, CN 1, US 3.
    expect(_topOf(tester, 'HK 2'), lessThan(_topOf(tester, 'CN 1')));
    expect(_topOf(tester, 'CN 1'), lessThan(_topOf(tester, 'US 3')));
  });

  testWidgets('sort by name reorders nodes alphabetically', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPage(tester);

    await _openSortMenu(tester);
    await tester.tap(find.byKey(const ValueKey('proxy-sort-name')));
    await tester.pumpAndSettle();

    expect(_topOf(tester, 'CN 1'), lessThan(_topOf(tester, 'HK 2')));
    expect(_topOf(tester, 'HK 2'), lessThan(_topOf(tester, 'US 3')));
  });

  testWidgets('sort by latency puts measured first and bad nodes last', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = DelayEdgeApi();
    await _pumpWith(
      tester,
      api: api,
      selection: RecordingProxySelection(api: api),
    );

    await _openSortMenu(tester);
    await tester.tap(find.byKey(const ValueKey('proxy-sort-latency')));
    await tester.pumpAndSettle();

    // Measured nodes first, ascending; null/0/-1 last in config order.
    expect(_topOf(tester, 'A-fast'), lessThan(_topOf(tester, 'E-slow')));
    expect(_topOf(tester, 'E-slow'), lessThan(_topOf(tester, 'B-blocked')));
    expect(_topOf(tester, 'B-blocked'), lessThan(_topOf(tester, 'C-timeout')));
    expect(_topOf(tester, 'C-timeout'), lessThan(_topOf(tester, 'D-unknown')));
    // Latency sort never hides a node.
    for (final name in <String>[
      'A-fast',
      'B-blocked',
      'C-timeout',
      'D-unknown',
      'E-slow',
    ]) {
      expect(find.byKey(ValueKey('proxy-node-$name')), findsOneWidget);
    }
  });

  testWidgets('hide toggle is off by default and explained', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = DelayEdgeApi();
    await _pumpWith(
      tester,
      api: api,
      selection: RecordingProxySelection(api: api),
    );

    final sw = tester.widget<Switch>(
      find.byKey(const ValueKey('proxy-hide-unavailable-switch')),
    );
    expect(sw.value, isFalse);
    // Every node stays visible with the opt-in toggle off.
    expect(find.byKey(const ValueKey('proxy-node-B-blocked')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-node-C-timeout')), findsOneWidget);
    // The toggle carries a readable label and explanation.
    expect(find.text('Hide blocked / timeout'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('proxy-hide-unavailable-switch')),
        matching: find.byType(Tooltip),
      ),
      findsOneWidget,
    );
  });

  testWidgets('hiding blocked and timeout nodes removes only those nodes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = DelayEdgeApi();
    await _pumpWith(
      tester,
      api: api,
      selection: RecordingProxySelection(api: api),
    );

    await tester.tap(
      find.byKey(const ValueKey('proxy-hide-unavailable-switch')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('proxy-node-B-blocked')), findsNothing);
    expect(find.byKey(const ValueKey('proxy-node-C-timeout')), findsNothing);
    // Measured nodes and the never-probed (null) node remain.
    expect(find.byKey(const ValueKey('proxy-node-A-fast')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-node-E-slow')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-node-D-unknown')), findsOneWidget);
  });

  testWidgets('group ping probes all nodes with progress and recomputes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeProxyApi();
    final selection = GatedProbeSelection(api: api);
    await _pumpWith(tester, api: api, selection: selection);

    expect(selection.probed, isEmpty); // no startup sweep
    final before = selection.bestCalls;

    await tester.tap(find.byKey(const ValueKey('proxy-group-ping')));
    await tester.pump();

    // Every member of the current group was probed.
    expect(selection.probed, unorderedEquals(<String>['HK 2', 'CN 1', 'US 3']));
    // Progress is shown and repeat taps are de-bounced while in flight.
    expect(
      find.byKey(const ValueKey('proxy-group-ping-progress')),
      findsOneWidget,
    );
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('proxy-group-ping')),
    );
    expect(button.onPressed, isNull);

    selection.release();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('proxy-group-ping-progress')),
      findsNothing,
    );
    // The recommendation is refreshed once the batch completes.
    expect(selection.bestCalls, greaterThan(before));
  });

  testWidgets('group ping keeps probing later batches after a node fails', (
    tester,
  ) async {
    final api = BatchProbeApi();
    final selection = BatchFailingProbeSelection(
      api: api,
      failing: BatchProbeApi.names.first, // in batch 1 of 2
    );
    await _pumpWith(tester, api: api, selection: selection);

    await tester.tap(find.byKey(const ValueKey('proxy-group-ping')));
    await tester.pumpAndSettle();

    // N59 is in the second batch: with the old Future.wait the first
    // batch's failure aborted before it was ever probed (P0-1).
    expect(selection.probed, hasLength(60));
    expect(selection.probed, contains(BatchProbeApi.names.last));
    expect(
      find.byKey(const ValueKey('proxy-group-ping-progress')),
      findsNothing,
    );
    // Ping completes cleanly and the list stays usable.
    expect(find.byKey(const ValueKey('proxy-best-state')), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('proxy-group-ping')),
    );
    expect(button.onPressed, isNotNull);
  });
}
