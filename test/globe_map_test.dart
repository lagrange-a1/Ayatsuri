import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/main.dart';
import 'package:ayatsuri/settings/app_settings.dart';

/// In-memory [SettingsStore] for widget tests. The production store needs
/// the platform plugin registrant, which `flutter test` does not run, so
/// injection via [AppSettingsController.storeFactory] is the supported seam.
class _MemorySettingsStore implements SettingsStore {
  _MemorySettingsStore([Map<String, String>? initial])
    : data = Map<String, String>.of(initial ?? const <String, String>{});

  final Map<String, String> data;

  @override
  String? getString(String key) => data[key];

  @override
  Future<void> setString(String key, String value) async {
    data[key] = value;
  }
}

/// Builds a controller whose lastCountry lives on the injected store.
/// `initial` fixes initialView without needing a settings JSON document.
Future<AppSettingsController> _controllerWith(
  Map<String, String> storeData, {
  required InitialView initialView,
}) async {
  final store = _MemorySettingsStore(storeData);
  final controller = AppSettingsController(
    initial: AppSettings(initialView: initialView),
    storeFactory: () async => store,
  );
  await controller.load();
  return controller;
}

/// Matches the test-only hook in GlobeMapPage that exposes the restored /
/// currently selected alpha-2 (see the `globe-restored-country-*` ValueKey).
Finder _restoredCountry(String alpha2) =>
    find.byKey(ValueKey('globe-restored-country-$alpha2'));

/// Load env + build the app with an injected settings controller.
/// `main()` is not called in widget tests, so dotenv must be installed here.
Future<void> _pumpAppWith(
  WidgetTester tester, {
  required AppSettingsController controller,
}) async {
  dotenv.loadFromString(envString: 'host=localhost\nport=9091\nsecret=***\n');
  await tester.pumpWidget(MyApp(settingsController: controller));
}

/// Load env + build the app with a default controller.
Future<void> _pumpApp(WidgetTester tester) async {
  dotenv.loadFromString(envString: 'host=localhost\nport=9091\nsecret=***\n');
  await tester.pumpWidget(MyApp());
}

/// Flush the startup/load-retry timers before the widget tree is disposed;
/// otherwise Flutter reports pending timers after the test ends.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 8));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Globe shows loading indicator on first frame', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    // First frame: selection/geo data not yet loaded, so the loading
    // state must be distinguishable from the empty state.
    expect(find.byKey(const ValueKey('globe-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('globe-empty')), findsNothing);
    // Globe placeholder and hint remain visible behind the indicator.
    expect(find.text('Globe (3D unavailable in tests)'), findsOneWidget);
    expect(find.text('Tap a Country/Region'), findsOneWidget);
    // Flush pending timers (load retries) before disposal.
    await _settle(tester);
  });

  testWidgets('Data state is exclusive and hides the legend in tests', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    // First frame is `loading` only: the offline/error/empty/ready overlays
    // must not appear alongside the spinner.
    expect(find.byKey(const ValueKey('globe-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('globe-offline')), findsNothing);
    expect(find.byKey(const ValueKey('globe-error')), findsNothing);
    expect(find.byKey(const ValueKey('globe-empty')), findsNothing);
    expect(find.byKey(const ValueKey('globe-ready')), findsNothing);
    // The globe/3D pipeline is unavailable in widget tests, so the delayed
    // legend and last-probe pill must not render blank placeholders.
    expect(find.byKey(const ValueKey('globe-legend')), findsNothing);
    expect(find.byKey(const ValueKey('globe-last-probe')), findsNothing);
    await _settle(tester);
  });

  testWidgets('Screen-reader labels are present on the visible states', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    // Point markers cannot hold Semantics; in production the whole-globe
    // button is the keyboard/screen-reader path. In widget tests the globe
    // becomes a placeholder, so verify the built Semantics labels instead.
    expect(
      find.bySemanticsLabel(RegExp(r'Tap a Country/Region|点击国家/地区')),
      findsWidgets,
    );
    expect(find.bySemanticsLabel(RegExp(r'Loading|加载中')), findsWidgets);
    // The hint text assertion from the original first-frame test still holds.
    expect(find.text('Tap a Country/Region'), findsOneWidget);
    await _settle(tester);
  });

  testWidgets('auto view restores lastCountry from the injected store', (
    WidgetTester tester,
  ) async {
    final controller = await _controllerWith({
      lastCountryKey: 'JP',
    }, initialView: InitialView.auto);
    await _pumpAppWith(tester, controller: controller);
    // First frame: nothing restored yet.
    expect(_restoredCountry('none'), findsOneWidget);
    // Let selection load + _restoreLastCountryIfNeeded finish.
    await _settle(tester);
    // InitialView.auto restores the remembered alpha-2 and focuses it.
    expect(_restoredCountry('JP'), findsOneWidget);
    expect(_restoredCountry('none'), findsNothing);
    expect(controller.lastCountry, 'JP');
    expect(controller.lastLoadError, isNull);
  });

  testWidgets(
    'remembered lastCountry is ignored when initial view is not auto',
    (WidgetTester tester) async {
      final controller = await _controllerWith({
        lastCountryKey: 'JP',
      }, initialView: InitialView.custom);
      await _pumpAppWith(tester, controller: controller);
      await _settle(tester);
      // The restore is gated on InitialView.auto; custom keeps the country
      // unselected instead of overriding the configured view.
      expect(_restoredCountry('none'), findsOneWidget);
      expect(_restoredCountry('JP'), findsNothing);
    },
  );

  testWidgets(
    'malformed or missing lastCountry falls back without restoring or crashing',
    (WidgetTester tester) async {
      final controller = await _controllerWith({
        lastCountryKey: 'not-a-country-code',
      }, initialView: InitialView.auto);
      await _pumpAppWith(tester, controller: controller);
      await _settle(tester);
      // Corrupt value is ignored: no country restored, no crash, no error.
      expect(_restoredCountry('none'), findsOneWidget);
      expect(_restoredCountry('JP'), findsNothing);
      expect(controller.lastCountry, isNull);
      expect(controller.lastLoadError, isNull);
    },
  );
}
