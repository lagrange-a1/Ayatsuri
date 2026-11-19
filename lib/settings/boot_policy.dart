/*
 * Boot policy: a persisted, strongly-typed startup probe policy.
 *
 * Before this file, "start a probe at launch" and "start the auto-schedule
 * loop at launch" were scattered ad-hoc widget toggles, so nothing durable
 * could be consulted at init. This module gives those decisions one typed,
 * persisted home:
 *
 *   off              - no automatic work at startup (today's behaviour);
 *   probe            - run ONE full-group probe shortly after the page loads;
 *   probeAndSchedule - also start the periodic auto-schedule loop at startup.
 *
 * The value lives under its own SharedPreferences key
 * ([bootPolicyKey] = `ayatsuri_probe_bootstrap_v1`), independent of the main
 * settings JSON document. Persistence reuses the repo's [SettingsStore]
 * seam from `app_settings.dart` (production = `SharedPreferencesWithCache`,
 * tests inject an in-memory fake via the constructor's `storeFactory`).
 *
 * Parsing is tolerant: an unknown or corrupt stored value falls back to
 * [ProbeBootstrap.off], and a failed write never throws — a bad preference
 * must never block startup or crash a running probe.
 */
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart' show SettingsStore;

/// SharedPreferences key backing the boot policy. Kept independent of the
/// main settings document so changing it cannot corrupt other preferences.
const String bootPolicyKey = 'ayatsuri_probe_bootstrap_v1';

/// Strongly-typed startup policy consulted when the app initialises.
enum ProbeBootstrap {
  /// No automatic work at startup (matches historical behaviour).
  off,

  /// Run one full-group probe shortly after the page loads.
  probe,

  /// Run one probe and start the periodic auto-schedule loop at startup.
  probeAndSchedule,
}

class _WithCacheBootPolicyStore implements SettingsStore {
  _WithCacheBootPolicyStore(this._prefs);
  final SharedPreferencesWithCache _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
}

Future<SettingsStore> _defaultBootPolicyStore() async {
  final prefs = await SharedPreferencesWithCache.create(
    cacheOptions: const SharedPreferencesWithCacheOptions(
      allowList: {bootPolicyKey},
    ),
  );
  return _WithCacheBootPolicyStore(prefs);
}

/// Owns the persisted [ProbeBootstrap] and mirrors it into a public,
/// synchronously-updated [ValueNotifier] (the same pattern as
/// `SchedulerWrapper.backendPreferenceNotifier`, so a listening UI rebuilds
/// on the very next frame even when the consumer lives on another page).
///
/// App code uses [BootPolicyController.instance]. Tests construct their own
/// instance with an injected `storeFactory` and call [resetForTests] for
/// isolation.
class BootPolicyController extends ChangeNotifier {
  BootPolicyController({Future<SettingsStore> Function()? storeFactory})
    : _storeFactory = storeFactory ?? _defaultBootPolicyStore;

  /// Global access point for app code.
  static final BootPolicyController instance = BootPolicyController();

  final Future<SettingsStore> Function() _storeFactory;

  /// Public listenable mirror of [mode]. Updated synchronously before the
  /// first `await` in [set] and as soon as [load] has read the store.
  final ValueNotifier<ProbeBootstrap> notifier = ValueNotifier<ProbeBootstrap>(
    ProbeBootstrap.off,
  );

  /// Current policy. Derived from [notifier] so the two can never diverge.
  ProbeBootstrap get mode => notifier.value;

  /// Tolerant parse: only exact enum names are accepted; anything else
  /// (null, unknown, corrupt) falls back to [ProbeBootstrap.off].
  static ProbeBootstrap parse(String? raw) {
    if (raw == null) return ProbeBootstrap.off;
    for (final candidate in ProbeBootstrap.values) {
      if (candidate.name == raw) return candidate;
    }
    return ProbeBootstrap.off;
  }

  void _apply(ProbeBootstrap next) {
    notifier.value = next;
    notifyListeners();
  }

  /// Read the persisted policy. A missing/corrupt value resolves to
  /// [ProbeBootstrap.off]; a store failure is swallowed so startup is never
  /// blocked.
  Future<void> load() async {
    try {
      final store = await _storeFactory();
      _apply(parse(store.getString(bootPolicyKey)));
    } catch (_) {
      _apply(ProbeBootstrap.off);
    }
  }

  /// Persist [next]. The in-memory state (and [notifier]) is updated
  /// synchronously before the first `await`, so listeners react immediately;
  /// the write is best-effort and a failure never throws.
  Future<void> set(ProbeBootstrap next) async {
    _apply(next);
    try {
      final store = await _storeFactory();
      await store.setString(bootPolicyKey, next.name);
    } catch (_) {
      // A failed write must never break the running app.
    }
  }

  /// Test-only reset: back to the [ProbeBootstrap.off] default.
  void resetForTests() {
    _apply(ProbeBootstrap.off);
  }
}
