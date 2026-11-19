/* Regression: enabling the loopback address preset must keep 127/8 nodes out
 * of every scheduling candidate path, including the auto-select loop. */

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/proxies/address_filter.dart';
import 'package:ayatsuri/proxies/proxy_service.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/proxies/smart_selector.dart';

class _Scheduler extends SchedulerWrapper {
  Iterable<String>? lastCandidates;

  @override
  Future<List<NodeRank>> rank(Iterable<String> candidates) async {
    lastCandidates = candidates;
    return const <NodeRank>[];
  }
}

class _Selector extends SmartSelector {
  _Selector(SchedulerWrapper scheduler) : super(scheduler: scheduler);

  Iterable<String>? bestCandidates;

  @override
  Future<String?> best({Iterable<String>? candidates, String? current}) async {
    bestCandidates = candidates;
    if (candidates == null || candidates.isEmpty) return null;
    return candidates.first;
  }
}

class _Api extends MihomoAPI {
  final List<(String, String)> selectCalls = <(String, String)>[];

  @override
  Future<Response<dynamic>> getProxies() => Future<Response<dynamic>>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{
        'proxies': <String, dynamic>{
          '127.0.0.53': <String, dynamic>{
            'name': '127.0.0.53',
            'type': 'Direct',
            'alive': true,
          },
          'REAL 1': <String, dynamic>{
            'name': 'REAL 1',
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
      data: <String, dynamic>{
        'proxies': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'go',
            'type': 'Selector',
            'all': <String>['127.0.0.53', 'REAL 1'],
            'now': '127.0.0.53',
          },
        ],
      },
    ),
  );

  @override
  Future<Response<dynamic>> selectProxy(
    String name, {
    required String proxyName,
  }) async {
    selectCalls.add((name, proxyName));
    return Response<dynamic>(requestOptions: RequestOptions());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AddressFilterController.resetForTests();
  });

  test(
    'loopback preset removes 127/8 from the scheduling candidate set',
    () async {
      await AddressFilterController.setEnabled(<AddressPreset>{
        AddressPreset.loopback,
      });
      final api = _Api();
      final scheduler = _Scheduler();
      final selector = _Selector(scheduler);
      final selection = ProxySelection(api: api, selector: selector);
      await selection.load();

      expect(
        shouldHideAddress('127.0.0.53', AddressFilterController.enabled),
        isTrue,
      );
      expect(selection.nodesForGroup('go').map((p) => p.name), <String>[
        'REAL 1',
      ]);
      final best = await selection.bestProxy(
        candidates: const <String>['127.0.0.53', 'REAL 1'],
        current: '127.0.0.53',
      );
      expect(best, 'REAL 1');
      expect(selector.bestCandidates, <String>['REAL 1']);
      expect(scheduler.lastCandidates, isNull);
    },
  );

  test('auto-select commit boundary refuses a filtered node', () async {
    await AddressFilterController.setEnabled(<AddressPreset>{
      AddressPreset.loopback,
    });
    final api = _Api();
    final selection = ProxySelection(
      api: api,
      selector: _Selector(_Scheduler()),
    );
    await selection.load();

    expect(
      () => selection.select('go', '127.0.0.53'),
      throwsA(isA<ArgumentError>()),
    );
    expect(api.selectCalls, isEmpty);
    await selection.select('go', 'REAL 1');
    expect(api.selectCalls, <(String, String)>[('go', 'REAL 1')]);
  });

  test('routableNames strips filtered and placeholder candidates', () async {
    await AddressFilterController.setEnabled(<AddressPreset>{
      AddressPreset.loopback,
    });
    final selection = ProxySelection(
      api: _Api(),
      selector: _Selector(_Scheduler()),
    );
    expect(
      selection.routableNames(const <String>[
        '127.0.0.53',
        'DIRECT',
        'REAL 1',
        'localhost',
      ]),
      <String>['REAL 1'],
    );
  });
}
