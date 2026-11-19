import 'dart:convert';

import 'package:ayatsuri/settings/app_settings.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';
import 'package:ayatsuri/proxies/scheduler_wrapper.dart';
import 'package:ayatsuri/scheduler/frb_generated.dart';
import 'package:ayatsuri/settings/settings_page.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory [SettingsStore] for tests.
///
/// Production uses `SharedPreferencesWithCache`, whose async platform
/// (`SharedPreferencesAsyncPlatform`) is not available under
/// `flutter test` unless the plugin registrant runs; the legacy
/// `SharedPreferences.setMockInitialValues` therefore does not work
/// with it. Injection via `storeFactory` is the supported test seam.
class _FakeSettingsStore implements SettingsStore {
  _FakeSettingsStore([Map<String, String>? initial])
    : data = Map.of(initial ?? const {}),
      setStringCalls = [];

  final Map<String, String> data;
  final List<String> setStringCalls;

  @override
  String? getString(String key) => data[key];

  @override
  Future<void> setString(String key, String value) async {
    setStringCalls.add(value);
    data[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settings JSON round-trip preserves fields', () {
    const original = AppSettings(
      themeMode: ThemeMode.dark,
      pureBlack: true,
      textScale: 1.2,
      autoRotate: true,
      rotationSpeed: 0.01,
      markerScale: 1.5,
      initialView: InitialView.custom,
      customLat: 10,
      customLng: 20,
      maxDelayMs: 300,
      hideBlocked: true,
      probeSort: ProbeSort.name,
      compactNodeList: true,
      backgroundOpacity: 0.4,
      locale: AppLocale.zh,
      autoApplyRecommendation: true,
      serverUrl: 'http://192.168.0.2:9091',
      secret: 'foobar',
    );
    final restored = AppSettings.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.pureBlack, isTrue);
    expect(restored.textScale, 1.2);
    expect(restored.autoRotate, isTrue);
    expect(restored.rotationSpeed, 0.01);
    expect(restored.markerScale, 1.5);
    expect(restored.initialView, InitialView.custom);
    expect(restored.latLngLat, 10);
    expect(restored.latLngLng, 20);
    expect(restored.maxDelayMs, 300);
    expect(restored.hideBlocked, isTrue);
    expect(restored.probeSort, ProbeSort.name);
    expect(restored.compactNodeList, isTrue);
    expect(restored.backgroundOpacity, 0.4);
    expect(restored.locale, AppLocale.zh);
    expect(restored.autoApplyRecommendation, isTrue);
    expect(restored.serverUrl, 'http://192.168.0.2:9091');
    expect(restored.secret, 'foobar');
    expect(restored.locale.flutterLocale, const Locale('zh'));
  });

  test('locale defaults to follow-system and old JSON stays readable', () {
    expect(const AppSettings().locale, AppLocale.system);
    expect(AppLocale.system.flutterLocale, isNull);
    expect(AppLocale.en.flutterLocale, const Locale('en'));
    final restored = AppSettings.fromJson({'v': 1});
    expect(restored.locale, AppLocale.system);
    final bad = AppSettings.fromJson({'locale': 'xx'});
    expect(bad.locale, AppLocale.system);
  });

  test('corrupt stored settings fall back to defaults', () async {
    final errors = <Object>[];
    final store = _FakeSettingsStore({'ayatsuri_settings_v1': 'not-json{{{'});
    final controller = AppSettingsController(
      storeFactory: () async => store,
      onPersistenceError: (error, _) => errors.add(error),
    );
    await controller.load();
    expect(controller.loaded, isTrue);
    expect(controller.settings.themeMode, ThemeMode.system);
    expect(controller.lastLoadError, isNotNull);
    expect(errors, isNotEmpty);
  });

  test('settings persist through injected store', () async {
    final store = _FakeSettingsStore();
    final controller = AppSettingsController(storeFactory: () async => store);
    await controller.load();
    expect(controller.loaded, isTrue);
    expect(controller.lastLoadError, isNull);
    await controller.update(
      controller.settings.copyWith(themeMode: ThemeMode.dark),
    );
    expect(controller.lastSaveError, isNull);
    expect(store.getString('ayatsuri_settings_v1'), isNotNull);
    expect(
      store.getString('ayatsuri_settings_v1'),
      contains('"themeMode":"dark"'),
    );
    // Reloading from the same store restores the persisted value.
    final reloaded = AppSettingsController(storeFactory: () async => store);
    await reloaded.load();
    expect(reloaded.settings.themeMode, ThemeMode.dark);
  });

  test(
    'last country round-trips on its own key via the injected store',
    () async {
      final store = _FakeSettingsStore();
      final controller = AppSettingsController(storeFactory: () async => store);
      await controller.load();
      await controller.saveLastCountry('jp');
      expect(controller.lastCountry, 'JP');
      expect(store.getString(lastCountryKey), 'JP');
      expect(store.getString('ayatsuri_last_country_v1'), 'JP');
      // Independent key: the settings JSON document is untouched.
      expect(store.getString('ayatsuri_settings_v1'), isNull);

      final reloaded = AppSettingsController(storeFactory: () async => store);
      await reloaded.loadLastCountry();
      expect(reloaded.lastCountry, 'JP');
      expect(reloaded.lastLoadError, isNull);

      // Sentinel / malformed input never overwrites a good saved value.
      await reloaded.saveLastCountry('-99');
      await reloaded.saveLastCountry('X');
      await reloaded.saveLastCountry('');
      expect(store.getString(lastCountryKey), 'JP');
    },
  );

  test('corrupt last-country value is ignored without an error', () async {
    final errors = <Object>[];
    final store = _FakeSettingsStore({
      'ayatsuri_last_country_v1': 'not-a-country-code',
    });
    final controller = AppSettingsController(
      storeFactory: () async => store,
      onPersistenceError: (error, _) => errors.add(error),
    );
    await controller.loadLastCountry();
    expect(controller.lastCountry, isNull);
    expect(controller.lastLoadError, isNull);
    expect(errors, isEmpty);
    expect(controller.settings, const AppSettings());
  });

  testWidgets('settings page renders and persists theme mode change', (
    tester,
  ) async {
    final store = _FakeSettingsStore();
    final controller = AppSettingsController(storeFactory: () async => store);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        locale: controller.settings.locale.flutterLocale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsPage(controller: controller),
      ),
    );
    expect(find.text('Appearance'), findsOneWidget);
    // TextFields carry their own internal Scrollables, so
    // scrollUntilVisible's default byType(Scrollable) lookup would find
    // several; drag the list directly instead.
    Future<void> scrollTo(String text) async {
      for (var i = 0; i < 10 && find.text(text).evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      expect(find.text(text), findsOneWidget);
    }

    await scrollTo('Background');
    await scrollTo('Globe');
    await scrollTo('Nodes & probe');
    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').first);
    await tester.pumpAndSettle();
    expect(controller.settings.themeMode, ThemeMode.dark);
    expect(store.getString('ayatsuri_settings_v1'), isNotNull);
  });

  testWidgets('language switch applies Chinese live and persists', (
    tester,
  ) async {
    final store = _FakeSettingsStore();
    final controller = AppSettingsController(storeFactory: () async => store);
    await controller.load();
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) => MaterialApp(
          locale: controller.settings.locale.flutterLocale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsPage(controller: controller),
        ),
      ),
    );
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(controller.settings.locale, AppLocale.zh);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(store.getString('ayatsuri_settings_v1'), contains('"locale":"zh"'));
  });

  testWidgets('routing internals are hidden and color style is humanized', (
    tester,
  ) async {
    final controller = AppSettingsController(
      storeFactory: () async => _FakeSettingsStore(),
    );
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsPage(controller: controller),
      ),
    );
    // EMA/hysteresis are routing internals: the persisted fields survive but
    // the settings page must not expose model-tuning knobs to a node picker.
    expect(find.byKey(const ValueKey('settings-ema-alpha')), findsNothing);
    expect(find.byKey(const ValueKey('settings-hysteresis')), findsNothing);
    expect(find.text('EMA smoothing'), findsNothing);
    expect(find.text('Switch hysteresis'), findsNothing);
    // Raw enum identifiers were replaced with readable labels.
    expect(find.text('Seed first'), findsAtLeastNWidgets(1));
    expect(find.text('Content'), findsNothing);
  });

  testWidgets('routing core preference is switchable with a real status line', (
    tester,
  ) async {
    SchedulerWrapper.resetForTests();
    final controller = AppSettingsController(
      storeFactory: () async => _FakeSettingsStore(),
    );
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsPage(controller: controller),
      ),
    );

    // Scroll to the smart-routing section. Same drag technique as the sibling
    // widget tests: TextFields own extra Scrollables.
    for (
      var i = 0;
      i < 10 && find.text('Routing core').evaluate().isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -200));
      await tester.pumpAndSettle();
    }
    expect(find.text('Routing core'), findsOneWidget);
    expect(find.byType(SegmentedButton<RoutingBackend>), findsOneWidget);
    // The subtitle is an honest lifecycle status, not a fabricated badge.
    expect(find.textContaining('Rust backend'), findsWidgets);

    expect(SchedulerWrapper.backendPreference, RoutingBackend.rustFirst);
    await tester.tap(find.text('Force Dart'));
    await tester.pumpAndSettle();
    expect(SchedulerWrapper.backendPreference, RoutingBackend.forceDart);

    await tester.tap(find.text('Rust first'));
    await tester.pumpAndSettle();
    expect(SchedulerWrapper.backendPreference, RoutingBackend.rustFirst);
    SchedulerWrapper.resetForTests();
  });

  test('Rust backend failure is observable with a readable reason', () async {
    SchedulerWrapper.resetForTests();
    final w = SchedulerWrapper();
    await w.observe('A', 100);
    expect(SchedulerWrapper.rustStatus, RustBackendStatus.unavailable);
    expect(SchedulerWrapper.rustError, contains('has not been initialized'));
    expect(w.rustActive, isFalse);
    // The Dart fallback still ranks the sample.
    final rows = await w.rank(['A']);
    expect(rows, hasLength(1));
    expect(rows.single.proxy, 'A');
    SchedulerWrapper.resetForTests();
  });

  test('Rust backend really activates and preference can force Dart', () async {
    SchedulerWrapper.resetForTests();
    // The cdylib is produced by scripts/build-rust-linux.sh and discovered via
    // flutter_rust_bridge's ioDirectory (CWD = repo root under flutter test).
    await RustLib.init();
    final w = SchedulerWrapper();
    await w.observe('A', 100);
    await w.observe('A', 200);

    expect(SchedulerWrapper.rustStatus, RustBackendStatus.available);
    expect(SchedulerWrapper.rustError, isNull);
    expect(w.rustActive, isTrue);

    // These numbers come from the native core, not the Dart mirror.
    final rustRows = await w.rank(['A']);
    expect(rustRows, hasLength(1));
    expect(rustRows.single.samples, 2);
    expect(rustRows.single.ewma, closeTo(120.0, 1e-9));

    // Forcing Dart flips the active backend without losing the samples.
    SchedulerWrapper.setBackendPreference(RoutingBackend.forceDart);
    expect(w.rustActive, isFalse);
    final dartRows = await w.rank(['A']);
    expect(dartRows, hasLength(1));
    expect(dartRows.single.ewma, closeTo(120.0, 1e-9));

    // Switching back re-activates Rust immediately, with no reload.
    SchedulerWrapper.setBackendPreference(RoutingBackend.rustFirst);
    expect(w.rustActive, isTrue);
    expect((await w.rank(['A'])).single.samples, 2);
    SchedulerWrapper.resetForTests();
  });

  test('backend preference persists across a simulated restart', () async {
    SchedulerWrapper.resetForTests();
    SharedPreferences.setMockInitialValues(<String, Object>{});

    expect(SchedulerWrapper.backendPreference, RoutingBackend.rustFirst);
    await SchedulerWrapper.setBackendPreference(RoutingBackend.forceDart);

    // The value really reached storage — asserted independently of the
    // in-memory static field.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SchedulerWrapper.backendPreferenceKey), 'forceDart');

    // Simulate a process restart: only the in-memory static state is reset;
    // the mock store (like disk) keeps the written value.
    SchedulerWrapper.resetForTests();
    expect(SchedulerWrapper.backendPreference, RoutingBackend.rustFirst);
    await SchedulerWrapper.loadBackendPreference();
    expect(SchedulerWrapper.backendPreference, RoutingBackend.forceDart);
    expect(
      SchedulerWrapper.backendPreferenceNotifier.value,
      RoutingBackend.forceDart,
    );
    SchedulerWrapper.resetForTests();
  });

  test('backend preference notifier fires on set and on reset', () async {
    SchedulerWrapper.resetForTests();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final seen = <RoutingBackend>[];
    void listener() =>
        seen.add(SchedulerWrapper.backendPreferenceNotifier.value);
    SchedulerWrapper.backendPreferenceNotifier.addListener(listener);
    await SchedulerWrapper.setBackendPreference(RoutingBackend.forceDart);
    SchedulerWrapper.resetForTests();
    SchedulerWrapper.backendPreferenceNotifier.removeListener(listener);
    expect(seen, <RoutingBackend>[
      RoutingBackend.forceDart,
      RoutingBackend.rustFirst,
    ]);
  });

  test('unknown stored backend preference falls back to rustFirst', () async {
    SchedulerWrapper.resetForTests();
    SharedPreferences.setMockInitialValues(<String, Object>{
      SchedulerWrapper.backendPreferenceKey: 'bogus',
    });
    await SchedulerWrapper.loadBackendPreference();
    expect(SchedulerWrapper.backendPreference, RoutingBackend.rustFirst);
    SchedulerWrapper.resetForTests();
  });
}
