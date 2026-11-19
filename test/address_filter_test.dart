// test/address_filter_test.dart
//
// Unit tests for the pure CIDR/name filter, the bundled CN list and the
// independent SharedPreferences persistence (mirroring SchedulerWrapper).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ayatsuri/proxies/address_filter.dart';

int addr(int a, int b, int c, int d) => (a << 24) | (b << 16) | (c << 8) | d;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AddressFilterController.resetForTests();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    AddressFilterController.resetForTests();
  });

  group('IPv4 extraction', () {
    test('common subscription forms and bare literals', () {
      expect(extractIpv4('name | 1.2.3.4:443'), addr(1, 2, 3, 4));
      expect(extractIpv4('SS 10.0.0.1 香港'), addr(10, 0, 0, 1));
      expect(extractIpv4('127.0.0.1'), addr(127, 0, 0, 1));
      expect(extractIpv4('v2 192.168.1.1:1080'), addr(192, 168, 1, 1));
      expect(extractIpv4('no address here'), isNull);
    });

    test('lookaround prevents false positives', () {
      expect(extractIpv4('CN 1'), isNull);
      expect(extractIpv4('v2.6.1'), isNull);
      expect(extractIpv4('1.2.3.4.5'), isNull);
      expect(extractIpv4('999.1.1.1'), isNull);
      expect(extractIpv4('...'), isNull);
    });
  });

  group('CIDR matching', () {
    test('RFC1918 blocks hit, neighbours miss', () {
      const enabled = <AddressPreset>{AddressPreset.private};
      expect(shouldHideAddress('n 10.0.0.1', enabled), isTrue);
      expect(shouldHideAddress('n 172.16.0.1', enabled), isTrue);
      expect(shouldHideAddress('n 172.31.255.255', enabled), isTrue);
      expect(shouldHideAddress('n 192.168.1.1', enabled), isTrue);
      expect(shouldHideAddress('n 172.32.0.1', enabled), isFalse);
      expect(shouldHideAddress('n 192.169.0.1', enabled), isFalse);
      expect(shouldHideAddress('n 8.8.8.8', enabled), isFalse);
    });

    test('loopback covers 127/8 and the localhost token only', () {
      const enabled = <AddressPreset>{AddressPreset.loopback};
      expect(shouldHideAddress('n 127.0.0.1:9090', enabled), isTrue);
      expect(shouldHideAddress('LOCALHOST', enabled), isTrue);
      expect(shouldHideAddress('local | localhost | 2.2.2.2', enabled), isTrue);
      expect(shouldHideAddress('notlocalhost', enabled), isFalse);
      expect(shouldHideAddress('n 128.0.0.1', enabled), isFalse);
      expect(shouldHideAddress('no address', enabled), isFalse);
    });

    test('loopback covers IPv6 ::1 and IPv4-mapped loopback', () {
      const enabled = <AddressPreset>{AddressPreset.loopback};
      for (final name in <String>[
        '::1',
        '[::1]:443',
        'node ::1 hk',
        '::ffff:127.0.0.1',
        '::FFFF:127.0.0.1',
        '[::ffff:127.0.0.1]:1080',
        '[::FFFF:127.0.0.1]:1080',
      ]) {
        expect(shouldHideAddress(name, enabled), isTrue, reason: name);
      }
      // IPv6 addresses that merely end in ::1 are not loopback; IPv4 CIDR
      // presets are untouched by the added IPv6 detection.
      for (final name in <String>[
        '2001:db8::1',
        'fe80::1',
        'n 128.0.0.1',
        'no address',
      ]) {
        expect(shouldHideAddress(name, enabled), isFalse, reason: name);
      }
      const private = <AddressPreset>{AddressPreset.private};
      expect(shouldHideAddress('n 10.0.0.1', private), isTrue);
      expect(shouldHideAddress('n ::1', private), isFalse);
    });

    test('bucket index spans several first octets and handles /0', () {
      final index = IpCidrIndex.fromCidrs(const <String>[
        '10.0.0.0/7',
        '8.8.8.0/24',
      ]);
      expect(index.contains(addr(10, 1, 2, 3)), isTrue);
      expect(index.contains(addr(11, 255, 255, 255)), isTrue);
      expect(index.contains(addr(9, 0, 0, 1)), isFalse);
      expect(index.contains(addr(8, 8, 8, 8)), isTrue);
      expect(index.contains(addr(8, 8, 9, 8)), isFalse);

      final all = IpCidrIndex.fromCidrs(const <String>['0.0.0.0/0']);
      expect(all.contains(addr(255, 255, 255, 255)), isTrue);
    });
  });

  group('CN asset', () {
    test('asset is actually loaded, cached and matched', () async {
      final index = await AddressFilterController.loadCnIndex();
      expect(index, isNotNull);
      expect(index!.length, greaterThan(1000));
      expect(index.contains(addr(1, 0, 1, 1)), isTrue); // 1.0.1.0/24
      expect(index.contains(addr(223, 255, 252, 1)), isTrue);
      expect(index.contains(addr(8, 8, 8, 8)), isFalse);
      // "Load once and cache": same instance on the second call.
      expect(await AddressFilterController.loadCnIndex(), same(index));

      const enabled = <AddressPreset>{AddressPreset.cn};
      expect(shouldHideAddress('CN | 1.0.1.1:443', enabled), isTrue);
      expect(shouldHideAddress('US | 8.8.8.8:443', enabled), isFalse);
    });

    test('failed CN load clears the cache so the next call retries', () async {
      final originalLoader = AddressFilterController.cnAssetLoader;
      addTearDown(() => AddressFilterController.cnAssetLoader = originalLoader);

      AddressFilterController.cnAssetLoader = (path) {
        throw StateError('injected asset failure');
      };

      final failed = await AddressFilterController.loadCnIndex();
      expect(failed, isNull);
      expect(AddressFilterController.cnIndex, isNull);
      expect(AddressFilterController.cnIndexState, CnIndexState.failed);

      // The failed future is no longer cached: restoring the loader makes the
      // very next call load the real bundled asset instead of reusing failure.
      AddressFilterController.cnAssetLoader = originalLoader;
      final recovered = await AddressFilterController.loadCnIndex();
      expect(recovered, isNotNull);
      expect(recovered!.contains(addr(1, 0, 1, 1)), isTrue);
      expect(AddressFilterController.cnIndexState, CnIndexState.ready);
      expect(await AddressFilterController.loadCnIndex(), same(recovered));
    });

    test('CN preset degrades to empty when the index is unavailable', () {
      expect(AddressFilterController.cnIndex, isNull);
      expect(
        shouldHideAddress('CN | 1.0.1.1', const <AddressPreset>{
          AddressPreset.cn,
        }),
        isFalse,
      );
    });
  });

  group('persistence', () {
    test('empty by default hides nothing', () {
      expect(AddressFilterController.enabled, isEmpty);
      for (final name in <String>[
        '127.0.0.1',
        'localhost',
        '192.168.1.1',
        'CN | 1.0.1.1',
      ]) {
        expect(
          shouldHideAddress(name, AddressFilterController.enabled),
          isFalse,
          reason: name,
        );
      }
    });

    test('save/load round-trip and onChange notifier', () async {
      final seen = <Set<AddressPreset>>[];
      void listener() =>
          seen.add(AddressFilterController.enabledNotifier.value);
      AddressFilterController.enabledNotifier.addListener(listener);

      await AddressFilterController.setEnabled(<AddressPreset>{
        AddressPreset.private,
        AddressPreset.loopback,
      });
      expect(AddressFilterController.enabled, <AddressPreset>{
        AddressPreset.private,
        AddressPreset.loopback,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList(AddressFilterController.presetsKey)?.toSet(),
        <String>{'private', 'loopback'},
      );

      // Simulate a restart: only in-memory state is reset, storage survives.
      AddressFilterController.resetForTests();
      expect(AddressFilterController.enabled, isEmpty);
      await AddressFilterController.loadEnabled();
      expect(AddressFilterController.enabled, <AddressPreset>{
        AddressPreset.private,
        AddressPreset.loopback,
      });

      AddressFilterController.enabledNotifier.removeListener(listener);
      expect(seen, hasLength(3)); // set, reset, load
    });

    test('unknown stored names are discarded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AddressFilterController.presetsKey: <String>['bogus', 'private'],
      });
      await AddressFilterController.loadEnabled();
      expect(AddressFilterController.enabled, <AddressPreset>{
        AddressPreset.private,
      });
    });
  });
}
