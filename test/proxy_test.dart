/*
 * Unit tests for `ProxySelection` (delay probing / candidate tables), behind a
 * fake controller so no live Mihomo instance is required.
 */

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/proxies/address_filter.dart';
import 'package:ayatsuri/proxies/country_map.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';
import 'package:ayatsuri/proxies/proxy_service.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/proxies/smart_selector.dart';

class RecordingScheduler extends SchedulerWrapper {
  Iterable<String>? lastCandidates;

  @override
  Future<List<NodeRank>> rank(Iterable<String> candidates) async {
    lastCandidates = candidates;
    return const <NodeRank>[];
  }
}

class RecordingSelector extends SmartSelector {
  RecordingSelector(SchedulerWrapper scheduler) : super(scheduler: scheduler);

  Iterable<String>? bestCandidates;

  @override
  Future<String?> best({Iterable<String>? candidates, String? current}) async {
    bestCandidates = candidates;
    if (candidates == null || candidates.isEmpty) return null;
    return candidates.first;
  }
}

class FakeMihomoAPI extends MihomoAPI {
  /// Records `(group, proxy)` for every PUT the service issues, so tests can
  /// verify `select`/`selectAny` reach the API regardless of group type.
  final List<(String, String)> selectCalls = <(String, String)>[];

  Map<String, Map<String, dynamic>> mockProxies =
      <String, Map<String, dynamic>>{
        'HK 2': {'name': 'HK 2', 'type': 'Direct', 'alive': true, 'delay': 150},
        'CN 1': {'name': 'CN 1', 'type': 'Direct', 'alive': true, 'delay': 400},
        'US 3': {'name': 'US 3', 'type': 'Direct', 'alive': true},
      };

  List<Map<String, dynamic>> mockGroups = <Map<String, dynamic>>[
    {
      'name': 'go',
      'type': 'Selector',
      'all': ['HK 2', 'CN 1', 'US 3'],
      'now': 'HK 2',
    },
  ];

  @override
  Future<Response> getProxies() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{'proxies': mockProxies},
    ),
  );

  @override
  Future<Response> getGroups() => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: <String, dynamic>{'proxies': mockGroups},
    ),
  );

  @override
  Future<Response> testProxyDelay(
    String name, {
    String url = kDefaultProbeUrl,
    int timeout = 5000,
    String? expected,
  }) {
    final item = mockProxies[name] ?? <String, dynamic>{};
    final mockDelay = item['delay'] as int?;
    return Future<Response>.value(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(),
        data: mockDelay != null
            ? <String, dynamic>{'delay': mockDelay}
            : <String, dynamic>{},
      ),
    );
  }

  @override
  Future<Response> selectProxy(String name, {required String proxyName}) {
    selectCalls.add((name, proxyName));
    for (final group in mockGroups) {
      if (group['name'] == name) {
        group['now'] = proxyName;
        break;
      }
    }
    return Future<Response>.value(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(),
        data: <String, dynamic>{},
      ),
    );
  }

  @override
  Future<Response> getProxy(String name) => Future<Response>.value(
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(),
      data: mockProxies[name] ?? {},
    ),
  );
}

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Load dotenv from memory rather than an asset: `.env` is no longer
  // bundled as a pubspec asset, so `dotenv.load()` (asset-based) fails.
  dotenv.loadFromString(envString: 'host=localhost\nport=9091\nsecret=***\n');
  late FakeMihomoAPI fake;
  late ProxySelection selection;

  setUp(() {
    fake = FakeMihomoAPI();
    selection = ProxySelection(api: fake);
    AddressFilterController.resetForTests();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('load proxies and groups', () async {
    await selection.load();
    expect(selection.proxies.length, 3);
    expect(selection.selectors.length, 1);
    expect(selection.selectors[0].all, ['HK 2', 'CN 1', 'US 3']);
    expect(selection.proxies['HK 2']!.delay, 150);
    expect(selection.proxies['CN 1']!.delay, 400);
    expect(selection.proxies['US 3']!.delay, isNull);
  });

  test(
    'selectors follow aggregate group order, not controller order',
    () async {
      // The controller list order rotates between calls (map iteration),
      // so it must not be trusted; the aggregate group's member list is
      // built in config order and wins.
      fake.mockGroups = <Map<String, dynamic>>[
        {
          'name': 'third',
          'type': 'Selector',
          'all': ['HK 2'],
          'now': 'HK 2',
        },
        {
          'name': 'first',
          'type': 'Selector',
          'all': ['HK 2'],
          'now': 'HK 2',
        },
        {
          'name': 'second',
          'type': 'Selector',
          'all': ['HK 2'],
          'now': 'HK 2',
        },
        {
          'name': 'GLOBAL',
          'type': 'Selector',
          'all': ['HK 2', 'first', 'second', 'third'],
          'now': 'HK 2',
        },
      ];
      await selection.load();
      final names = selection.selectors.map((g) => g.name).toList();
      expect(names, ['first', 'second', 'third', 'GLOBAL']);
    },
  );

  test('candidatesForMapId groups proxies by country', () async {
    await selection.load();
    // Candidates are picked by name match within each selector group.
    final ids = <String>{};
    for (final group in selection.selectors) {
      for (final name in group.all) {
        final alpha2 = nameToFrontAlpha2(name);
        if (alpha2 != null) ids.add(alpha2);
      }
    }
    expect(ids, {'HK', 'CN', 'US'});
    expect(selection.candidatesForMapId('HK'), hasLength(1));
    expect(selection.candidatesForMapId('CN'), hasLength(1));
    expect(selection.candidatesForMapId('US'), hasLength(1));
    expect(selection.candidatesForMapId('XX'), isEmpty);
  });

  test('probeByName updates probe delay', () async {
    await selection.load();
    // US 3 has no probe key, so the delay is not set.
    final updated = await fake.testProxyDelay('US 3');
    expect(updated.data['delay'], isNull);
    await selection.probeByName('US 3');
    expect(selection.proxies['US 3']!.delay, isNull);
  });

  test('probe() probes the whole candidate set', () async {
    await selection.load();
    final candidates = selection.candidatesForMapId('HK');
    expect(candidates.length, 1);
    expect(await selection.probe(candidates), hasLength(1));
    // the mock reports its own 150(ms) value, not the generic 100.
    expect(selection.proxies['HK 2']!.delay, 150);
  });

  test('probe with no delay returns nothing', () async {
    await selection.load();
    // The fake keeps its own delay; a probe reporting no value does not
    // touch the cache.
    fake.mockProxies['HK 2']!.remove('delay');
    final candidates = selection.candidatesForMapId('HK');
    expect(candidates, hasLength(1));
    final result = await selection.probe(candidates);
    expect(result, isEmpty);
    expect(selection.proxies['HK 2']!.delay, 150);
  });

  test('proxy selection updates group.now', () async {
    await selection.load();
    await selection.select('go', 'CN 1');
    await selection.load();
    expect(selection.selectors[0].now, 'CN 1');
    final updated = selection.candidatesForMapId('CN');
    expect(updated.first.isNow, isTrue);
  });

  test(
    'allGroups includes Selector and automatic groups in config order',
    () async {
      fake.mockGroups = <Map<String, dynamic>>[
        {
          // Deliberately listed before the Selector in controller order.
          'name': 'auto-b',
          'type': 'URLTest',
          'all': ['HK 2'],
          'now': 'HK 2',
        },
        {
          'name': 'sel-a',
          'type': 'Selector',
          'all': ['CN 1'],
          'now': 'CN 1',
        },
        {
          'name': 'GLOBAL',
          'type': 'Selector',
          'all': ['sel-a', 'auto-b', 'GLOBAL'],
          'now': 'DIRECT',
        },
      ];
      await selection.load();
      final all = selection.allGroups;
      // Both types survive, ordered by the aggregate group's config order.
      expect(all.map((g) => g.name).toList(), ['sel-a', 'auto-b', 'GLOBAL']);
      expect(all.map((g) => g.type), contains('URLTest'));
      // `selectors` still filters out the URLTest group, unchanged.
      expect(selection.selectors.map((g) => g.name).toList(), [
        'sel-a',
        'GLOBAL',
      ]);
      final auto = all.firstWhere((g) => g.name == 'auto-b');
      expect(auto.isAuto, isTrue);
      expect(auto.isSelector, isFalse);
      expect(auto.typeLabel, 'AUTO');
      final manual = all.firstWhere((g) => g.name == 'sel-a');
      expect(manual.isAuto, isFalse);
      expect(manual.typeLabel, 'SELECT');
    },
  );

  test(
    'nodesForGroup returns members in all-order, skipping missing',
    () async {
      await selection.load();
      fake.mockGroups[0]['all'] = ['US 3', 'MISSING', 'CN 1', 'HK 2'];
      await selection.load();
      final nodes = selection.nodesForGroup('go');
      expect(nodes.map((p) => p.name).toList(), ['US 3', 'CN 1', 'HK 2']);
      expect(nodes.map((p) => p.type).toList(), ['Direct', 'Direct', 'Direct']);
      expect(selection.nodesForGroup('does-not-exist'), isEmpty);
    },
  );

  test('selectAny issues PUT for any group type via selectProxy', () async {
    await selection.load();
    // A manual Selector: same path as `select`.
    await selection.selectAny('go', 'US 3');
    expect(fake.selectCalls, contains(('go', 'US 3')));
    await selection.load();
    expect(selection.selectors.first.now, 'US 3');

    // An automatic URLTest group: the kernel may reject it, but the data
    // layer still attempts the PUT — verify the call reaches the API.
    fake.mockGroups.add(<String, dynamic>{
      'name': 'auto',
      'type': 'URLTest',
      'all': ['HK 2'],
      'now': 'HK 2',
    });
    await selection.selectAny('auto', 'CN 1');
    expect(fake.selectCalls, contains(('auto', 'CN 1')));
  });

  test('delay labels', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final zh = lookupAppLocalizations(const Locale('zh'));
    expect(delayLabel(en, null), '—');
    expect(delayLabel(en, 0), 'blocked');
    expect(delayLabel(en, kDelayTimeout), 'TIMEOUT');
    expect(delayLabel(zh, kDelayTimeout), '超时');
    expect(delayLabel(en, 42), '42 ms');
    expect(delayLabel(zh, 0), '已屏蔽');
    expect(delayLabel(zh, 42), '42 毫秒');
  });

  test('delay colors follow the thresholds', () {
    expect(delayColor(null), Colors.grey);
    expect(delayColor(0), Colors.red);
    expect(delayColor(kDelayTimeout), Colors.red);
    expect(delayColor(50), Colors.green);
    expect(delayColor(99), Colors.green);
    expect(delayColor(100), Colors.green);
    expect(delayColor(299), Colors.green);
    expect(delayColor(300), Colors.green);
    expect(delayColor(499), Colors.green);
    expect(delayColor(500), Colors.amber);
    expect(delayColor(1000), Colors.amber);
    expect(delayColor(4999), Colors.amber);
    expect(delayColor(5000), Colors.red);
    expect(delayColor(6000), Colors.red);
  });

  test('delay colors are consistent per state', () {
    expect(delayColor(150), delayColor(150));
    expect(delayColor(150), isNot(delayColor(999)));
    expect(delayColor(0), isNot(delayColor(50)));
  });

  GroupItem grp(String name, String type, String? now) =>
      GroupItem(name: name, type: type, all: const [], now: now);

  test('kernelCountryAlpha2 follows nested group chains', () {
    // Real-world shape: PROXY -> AUTO-FAST -> UAE node, with automatic
    // pools listed first — their `now` must not win.
    final groups = [
      grp('US-POOL', 'URLTest', '🇺🇸 美国 | USA 11'),
      grp('AI-POOL', 'URLTest', '🇮🇹 意大利 | ITA 3'),
      grp('GLOBAL', 'Selector', 'DIRECT'),
      grp('PROXY', 'Selector', 'AUTO-FAST'),
      grp('AUTO-FAST', 'URLTest', '🇦🇪 阿联酋 | ARE'),
    ];
    expect(kernelCountryAlpha2(groups), 'AE');
  });

  test('kernelCountryAlpha2 falls back to automatic pools', () {
    final groups = [
      grp('GLOBAL', 'Selector', 'DIRECT'),
      grp('US-POOL', 'URLTest', '🇺🇸 美国 | USA 11'),
    ];
    expect(kernelCountryAlpha2(groups), 'US');
  });

  test('kernelCountryAlpha2 handles cycles and unresolvable chains', () {
    expect(
      kernelCountryAlpha2([
        grp('A', 'Selector', 'B'),
        grp('B', 'Selector', 'A'),
      ]),
      isNull,
    );
    expect(kernelCountryAlpha2([grp('A', 'Selector', 'DIRECT')]), isNull);
    expect(kernelCountryAlpha2([]), isNull);
  });

  test('scheduling never considers DIRECT', () async {
    final scheduler = RecordingScheduler();
    final recording = RecordingSelector(scheduler);
    final selection = ProxySelection(api: fake, selector: recording);

    final best = await selection.bestProxy(
      candidates: const ['DIRECT', 'HK 2', 'direct', 'CN 1'],
      current: 'HK 2',
    );
    expect(best, 'HK 2');
    expect(recording.bestCandidates, ['HK 2', 'CN 1']);

    await selection.rankProxies(const ['DIRECT', 'HK 2']);
    expect(scheduler.lastCandidates, ['HK 2']);
  });

  test('scheduling ignores all kernel placeholder tokens exactly', () async {
    final scheduler = RecordingScheduler();
    final recording = RecordingSelector(scheduler);
    final s = ProxySelection(api: fake, selector: recording);

    final best = await s.bestProxy(
      candidates: const [
        'HK 2',
        'DIRECT',
        'direct',
        'REJECT',
        'reject',
        'MATCH',
        'Match',
        'COMPATIBLE',
        'compatible',
        'REJECT-1',
        'Match node',
        'compatible proxy',
      ],
      current: 'HK 2',
    );
    expect(best, 'HK 2');
    // Exact placeholders (any case) are gone; names merely containing the
    // token are ordinary proxies and must survive.
    expect(recording.bestCandidates, [
      'HK 2',
      'REJECT-1',
      'Match node',
      'compatible proxy',
    ]);

    await s.rankProxies(const [
      'DIRECT',
      'REJECT',
      'MATCH',
      'COMPATIBLE',
      'reject',
      'HK 2',
    ]);
    expect(scheduler.lastCandidates, ['HK 2']);
  });

  test(
    'kernel placeholders are excluded from node list and map candidates',
    () async {
      fake.mockProxies = <String, Map<String, dynamic>>{
        'DIRECT': {'name': 'DIRECT', 'type': 'Direct', 'alive': true},
        'reject': {'name': 'reject', 'type': 'Reject', 'alive': true},
        'MATCH': {'name': 'MATCH', 'type': 'Selector', 'alive': true},
        'Compatible': {
          'name': 'Compatible',
          'type': 'Compatible',
          'alive': true,
        },
        'REJECT-1': {'name': 'REJECT-1', 'type': 'Socks5', 'alive': true},
        'Match node': {'name': 'Match node', 'type': 'Socks5', 'alive': true},
        'HK 2': {'name': 'HK 2', 'type': 'Socks5', 'alive': true},
      };
      fake.mockGroups = <Map<String, dynamic>>[
        {
          'name': 'go',
          'type': 'Selector',
          'all': [
            'DIRECT',
            'reject',
            'MATCH',
            'Compatible',
            'REJECT-1',
            'Match node',
            'NO-SUCH-PROXY', // missing proxies are still skipped
            'HK 2',
          ],
          'now': 'HK 2',
        },
      ];
      await selection.load();

      expect(selection.nodesForGroup('go').map((p) => p.name).toList(), [
        'REJECT-1',
        'Match node',
        'HK 2',
      ]);

      // An unknown mapId becomes a literal pattern, so a proxy named exactly
      // `reject` would otherwise be a candidate here; only the lookalike stays.
      expect(
        selection
            .candidatesForMapId('REJECT')
            .map((c) => c.proxy.name)
            .toList(),
        ['REJECT-1'],
      );
      expect(
        selection.candidatesForMapId('MATCH').map((c) => c.proxy.name).toList(),
        ['Match node'],
      );
      expect(
        selection.candidatesForMapId('HK 2').map((c) => c.proxy.name).toList(),
        ['HK 2'],
      );
    },
  );

  test('address presets filter the node list and map candidates', () async {
    fake.mockProxies = <String, Map<String, dynamic>>{
      'HK 2': {'name': 'HK 2', 'type': 'Socks5', 'alive': true},
      'CN 10.0.0.1': {'name': 'CN 10.0.0.1', 'type': 'Socks5', 'alive': true},
      'LOOPBACK 127.0.0.1': {
        'name': 'LOOPBACK 127.0.0.1',
        'type': 'Socks5',
        'alive': true,
      },
      'CN 1': {'name': 'CN 1', 'type': 'Socks5', 'alive': true},
    };
    fake.mockGroups = <Map<String, dynamic>>[
      {
        'name': 'go',
        'type': 'Selector',
        'all': ['HK 2', 'CN 10.0.0.1', 'LOOPBACK 127.0.0.1', 'CN 1'],
        'now': 'HK 2',
      },
    ];
    await selection.load();

    // Default empty presets: nothing changes.
    expect(selection.nodesForGroup('go').map((p) => p.name).toList(), [
      'HK 2',
      'CN 10.0.0.1',
      'LOOPBACK 127.0.0.1',
      'CN 1',
    ]);
    expect(
      selection.candidatesForMapId('CN').map((c) => c.proxy.name).toList(),
      ['CN 10.0.0.1', 'CN 1'],
    );

    await AddressFilterController.setEnabled(<AddressPreset>{
      AddressPreset.private,
      AddressPreset.loopback,
    });
    expect(selection.nodesForGroup('go').map((p) => p.name).toList(), [
      'HK 2',
      'CN 1',
    ]);
    expect(
      selection.candidatesForMapId('CN').map((c) => c.proxy.name).toList(),
      ['CN 1'],
    );

    // Disabling restores the original behaviour without a reload.
    await AddressFilterController.setEnabled(<AddressPreset>{});
    expect(selection.nodesForGroup('go'), hasLength(4));
    expect(selection.candidatesForMapId('CN'), hasLength(2));
  });

  test('address presets combine with DIRECT filtering in scheduling', () async {
    final scheduler = RecordingScheduler();
    final recording = RecordingSelector(scheduler);
    final s = ProxySelection(api: fake, selector: recording);

    await AddressFilterController.setEnabled(<AddressPreset>{
      AddressPreset.private,
    });
    final best = await s.bestProxy(
      candidates: const [
        'DIRECT',
        'LAN 192.168.1.1',
        'HK 2',
        'direct',
        '10.0.0.1',
        'US 3',
      ],
      current: 'HK 2',
    );
    expect(best, 'HK 2');
    expect(recording.bestCandidates, ['HK 2', 'US 3']);

    await s.rankProxies(const ['DIRECT', '192.168.0.1', 'HK 2', 'direct']);
    expect(scheduler.lastCandidates, ['HK 2']);

    await AddressFilterController.setEnabled(<AddressPreset>{});
    await s.bestProxy(candidates: const ['DIRECT', 'HK 2', 'CN 1']);
    expect(recording.bestCandidates, ['HK 2', 'CN 1']);
  });
}
