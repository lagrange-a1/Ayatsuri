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
/// returns a deterministic best-proxy suggestion for the badge test.
class RecordingProxySelection extends ProxySelection {
  RecordingProxySelection({required MihomoAPI api, this.best})
    : super(api: api);

  final String? best;
  final List<(String, String)> selects = <(String, String)>[];
  final List<(String, String)> selectAnys = <(String, String)>[];

  @override
  Future<String?> bestProxy({
    Iterable<String>? candidates,
    String? current,
  }) async => best;

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
/// exercise the generation guard.
class RaceProxySelection extends ProxySelection {
  RaceProxySelection({required MihomoAPI api}) : super(api: api);

  final List<Completer<String?>> _answers = <Completer<String?>>[];
  final List<Iterable<String>?> candidateCalls = <Iterable<String>?>[];

  @override
  Future<String?> bestProxy({Iterable<String>? candidates, String? current}) {
    candidateCalls.add(candidates);
    final completer = Completer<String?>();
    _answers.add(completer);
    return completer.future;
  }

  void answer(int call, String? node) => _answers[call].complete(node);
}

Future<RecordingProxySelection> _pumpPage(
  WidgetTester tester, {
  String? best,
  bool failSelect = false,
}) async {
  final api = FakeProxyApi()..failSelect = failSelect;
  final selection = RecordingProxySelection(api: api, best: best);
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
  return selection;
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
    await _pumpPage(tester, best: 'CN 1');
    expect(
      find.byKey(const ValueKey('proxy-recommended-CN 1')),
      findsOneWidget,
    );
    expect(find.text('Recommended'), findsOneWidget);
    // The current node (HK 2) never receives the recommendation badge.
    expect(find.byKey(const ValueKey('proxy-recommended-HK 2')), findsNothing);
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

    final nowTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('proxy-node-HK 2')),
    );
    expect(nowTile.selected, isTrue);
    expect(nowTile.selectedTileColor, isNotNull);

    final otherTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('proxy-node-CN 1')),
    );
    expect(otherTile.selected, isFalse);
    expect(find.text('Force-select auto groups'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('proxy-auto-badge-AUTO-POOL')),
        matching: find.byType(Tooltip),
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
    // The initial bestProxy answer is held pending, so the loading spinner
    // animates: single pumps, not pumpAndSettle, until the last answer.
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
}
