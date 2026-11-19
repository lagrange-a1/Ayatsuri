import 'package:ayatsuri/settings/app_settings.dart' show SettingsStore;
import 'package:ayatsuri/settings/boot_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [SettingsStore] for tests; mirrors the fake in settings_test.dart.
class _FakeBootStore implements SettingsStore {
  _FakeBootStore([Map<String, String>? initial])
    : data = Map<String, String>.from(initial ?? const <String, String>{});

  final Map<String, String> data;

  @override
  String? getString(String key) => data[key];

  @override
  Future<void> setString(String key, String value) async {
    data[key] = value;
  }
}

/// Store whose writes always fail, to prove a failed write never throws.
class _ThrowingWriteStore implements SettingsStore {
  @override
  String? getString(String key) => null;

  @override
  Future<void> setString(String key, String value) =>
      throw StateError('injected write failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exposed key is the documented v1 key', () {
    expect(bootPolicyKey, 'ayatsuri_probe_bootstrap_v1');
  });

  test('default policy is off', () {
    final controller = BootPolicyController(
      storeFactory: () async => _FakeBootStore(),
    );
    expect(controller.mode, ProbeBootstrap.off);
    expect(controller.notifier.value, ProbeBootstrap.off);
  });

  test(
    'round-trip: set persists and a fresh controller loads it back',
    () async {
      final store = _FakeBootStore();
      final controller = BootPolicyController(storeFactory: () async => store);

      await controller.set(ProbeBootstrap.probeAndSchedule);
      expect(store.getString(bootPolicyKey), 'probeAndSchedule');

      // Simulate a process restart: new controller over the same store.
      final reloaded = BootPolicyController(storeFactory: () async => store);
      await reloaded.load();
      expect(reloaded.mode, ProbeBootstrap.probeAndSchedule);
      expect(reloaded.notifier.value, ProbeBootstrap.probeAndSchedule);
    },
  );

  test('all three values round-trip independently', () async {
    final store = _FakeBootStore();
    for (final value in ProbeBootstrap.values) {
      final controller = BootPolicyController(storeFactory: () async => store);
      await controller.set(value);
      final reloaded = BootPolicyController(storeFactory: () async => store);
      await reloaded.load();
      expect(reloaded.mode, value, reason: 'round-trip for ${value.name}');
    }
  });

  test('corrupt stored value falls back to off', () async {
    final store = _FakeBootStore(<String, String>{bootPolicyKey: 'bogus'});
    final controller = BootPolicyController(storeFactory: () async => store);
    await controller.load();
    expect(controller.mode, ProbeBootstrap.off);
    expect(controller.notifier.value, ProbeBootstrap.off);
    expect(store.getString(bootPolicyKey), 'bogus'); // untouched
  });

  test('parse tolerates null, unknown and wrong-case values', () {
    expect(BootPolicyController.parse(null), ProbeBootstrap.off);
    expect(BootPolicyController.parse(''), ProbeBootstrap.off);
    expect(BootPolicyController.parse('PROBE'), ProbeBootstrap.off);
    expect(BootPolicyController.parse('probe'), ProbeBootstrap.probe);
    expect(
      BootPolicyController.parse('probeAndSchedule'),
      ProbeBootstrap.probeAndSchedule,
    );
  });

  test(
    'notifier updates synchronously on set, before the write completes',
    () async {
      final controller = BootPolicyController(
        storeFactory: () async => _FakeBootStore(),
      );
      final seen = <ProbeBootstrap>[];
      void listener() => seen.add(controller.notifier.value);
      controller.notifier.addListener(listener);

      final pending = controller.set(ProbeBootstrap.probe);
      // No await yet: the notifier must already reflect the new policy.
      expect(controller.notifier.value, ProbeBootstrap.probe);
      expect(seen, <ProbeBootstrap>[ProbeBootstrap.probe]);
      await pending;
      controller.notifier.removeListener(listener);
    },
  );

  test('failed write never throws and keeps the in-memory value', () async {
    final controller = BootPolicyController(
      storeFactory: () async => _ThrowingWriteStore(),
    );
    await controller.set(ProbeBootstrap.probeAndSchedule);
    expect(controller.mode, ProbeBootstrap.probeAndSchedule);
  });

  test('failed load never throws and falls back to off', () async {
    final controller = BootPolicyController(
      storeFactory: () => throw StateError('injected store failure'),
    );
    await controller.load();
    expect(controller.mode, ProbeBootstrap.off);
  });

  test('resetForTests returns the controller to off', () async {
    final controller = BootPolicyController(
      storeFactory: () async => _FakeBootStore(),
    );
    await controller.set(ProbeBootstrap.probe);
    expect(controller.mode, ProbeBootstrap.probe);
    controller.resetForTests();
    expect(controller.mode, ProbeBootstrap.off);
    expect(controller.notifier.value, ProbeBootstrap.off);
  });
}
