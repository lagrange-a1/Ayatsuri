/*
 * Ordered application bootstrap.
 *
 * The old `main()` was a loose, linear list of `await`s: an ad-hoc sequence
 * that could not be inspected or tested as a unit. This module makes the
 * startup sequence an explicit contract:
 *
 *   env -> settings load -> runtime policies
 *        [AppSettings, SchedulerWrapper backend, AddressFilter,
 *         BootPolicyController] -> rust init -> ready
 *
 * Every step is a named function called from [bootstrap] in one visible
 * order (mirrored by [bootstrapPhaseOrder] for tests). Each step is wrapped
 * by [_guard]: a failure is logged and swallowed so a non-critical phase can
 * never block the phases after it. All of the underlying restores already
 * degrade gracefully (defaults on corrupt/missing data), so the guards are a
 * second line of defence rather than a behaviour change.
 */
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../proxies/address_filter.dart';
import '../proxies/scheduler_wrapper.dart';
import '../scheduler/frb_generated.dart';
import '../settings/app_settings.dart';
import '../settings/boot_policy.dart';

/// Immutable snapshot of the services initialised by [bootstrap] and handed
/// to the app shell. Constructed only once, after every phase has run.
class AppServices {
  const AppServices({
    required this.settingsController,
    required this.probeMode,
  });

  /// Loaded settings, shared with `MyApp`/`MihomoApp`.
  final AppSettingsController settingsController;

  /// Persisted startup probe policy, read through the singleton documented
  /// by `policy-core` (`BootPolicyController.instance`).
  final ProbeBootstrap probeMode;
}

/// Phase labels [bootstrap] executes, in exact order. Exposed so the sequence
/// is assertable without parsing source.
const List<String> bootstrapPhaseOrder = <String>[
  'env',
  'settings load',
  'runtime policies/AppSettings',
  'runtime policies/SchedulerWrapper backend',
  'runtime policies/AddressFilter',
  'runtime policies/BootPolicyController',
  'rust init',
  'ready',
];

/// Runs one named phase, logging and swallowing any failure so the rest of
/// startup continues. Non-critical by construction.
Future<T?> _guard<T>(String label, Future<T> Function() phase) async {
  try {
    return await phase();
  } catch (e, stack) {
    debugPrint('[Ayatsuri] bootstrap phase "$label" failed (ignored): $e');
    debugPrint('$stack');
    return null;
  }
}

/// Phase: `env`. Binds the framework and loads the optional dev `.env`.
Future<void> _phaseEnv() async {
  WidgetsFlutterBinding.ensureInitialized();
  // `.env` is a dev-only fallback and is no longer a bundled asset, so a
  // normal run has no file to load. An optional load yields empty env instead
  // of throwing; the catch is a last resort for a corrupt file so MihomoAPI
  // never sees an uninitialised dotenv.
  try {
    await dotenv.load(isOptional: true);
  } catch (_) {
    dotenv.loadFromString(isOptional: true);
  }
}

/// Phase: `settings load`. Creates and restores the main settings document.
Future<AppSettingsController> _phaseSettingsLoad() async {
  final controller = AppSettingsController();
  await controller.load();
  return controller;
}

/// Phase: `runtime policies/AppSettings`. Confirms the AppSettings policy is
/// resolved before the other policies are read. `load()` already ran above,
/// so this is normally a no-op; it only re-loads if a guard skipped it.
Future<void> _policyAppSettings(AppSettingsController settings) async {
  if (!settings.loaded) await settings.load();
}

/// Phase: `runtime policies/SchedulerWrapper backend`. Restores the persisted
/// routing backend before the first frame so the settings page and scheduler
/// chip never flash the wrong value.
Future<void> _policySchedulerBackend() async {
  await SchedulerWrapper.loadBackendPreference();
}

/// Phase: `runtime policies/AddressFilter`. Restores persisted address-bypass
/// presets (prefetching the CN CIDR index when that preset is enabled).
Future<void> _policyAddressFilter() async {
  await AddressFilterController.loadEnabled();
}

/// Phase: `runtime policies/BootPolicyController`. Reads the one durable
/// startup-probe decision through the singleton; unknown/corrupt values
/// resolve to `off` inside the controller.
Future<ProbeBootstrap> _policyBootPolicy() async {
  await BootPolicyController.instance.load();
  return BootPolicyController.instance.mode;
}

/// The `runtime policies` phase group, in named sub-step order. Each sub-step
/// is guarded individually so one policy failing cannot block the next.
Future<ProbeBootstrap> _phaseRuntimePolicies(
  AppSettingsController settings,
) async {
  await _guard(
    'runtime policies/AppSettings',
    () => _policyAppSettings(settings),
  );
  await _guard(
    'runtime policies/SchedulerWrapper backend',
    _policySchedulerBackend,
  );
  await _guard('runtime policies/AddressFilter', _policyAddressFilter);
  final mode = await _guard(
    'runtime policies/BootPolicyController',
    _policyBootPolicy,
  );
  return mode ?? ProbeBootstrap.off;
}

/// Phase: `rust init`. Attaches the Rust scheduler when a native library is
/// bundled; a missing dylib (tests, web, older installs) is fine because
/// SchedulerWrapper falls back to its equivalent Dart implementation.
Future<void> _phaseRustInit() async {
  try {
    await RustLib.init();
  } catch (e) {
    debugPrint('[Ayatsuri] Rust scheduler init failed: $e');
  }
}

/// Phase: `ready`. Packages the resolved services for the app shell.
AppServices _phaseReady(AppSettingsController settings, ProbeBootstrap mode) =>
    AppServices(settingsController: settings, probeMode: mode);

/// Runs every named phase in the fixed order documented by
/// [bootstrapPhaseOrder] and returns the immutable [AppServices] snapshot.
Future<AppServices> bootstrap() async {
  // env
  await _guard('env', _phaseEnv);

  // settings load
  final settings =
      await _guard('settings load', _phaseSettingsLoad) ??
      AppSettingsController();

  // runtime policies
  final mode =
      await _guard('runtime policies', () => _phaseRuntimePolicies(settings)) ??
      ProbeBootstrap.off;

  // rust init
  await _guard('rust init', _phaseRustInit);

  // ready
  return _phaseReady(settings, mode);
}
