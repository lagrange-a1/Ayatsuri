import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'proxies/address_filter.dart';
import 'proxies/scheduler_wrapper.dart';
import 'scheduler/frb_generated.dart';
import 'settings/app_settings.dart';

// Only the process entrypoint lives here: bootstrap, load settings, hand off
// to the app shell. MyApp/MihomoApp moved to app.dart so this file has a
// single responsibility, like a kernel entrypoint that sets up and calls in.
export 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // .env is a dev-only fallback and is no longer bundled as a pubspec
  // asset, so on a normal `flutter run` the file is absent from the asset
  // bundle and `dotenv.load()` would throw. Ask for an optional load so a
  // missing .env simply yields an empty env (defaults apply) instead of
  // leaving dotenv uninitialized and tripping the guard in MihomoAPI.
  // The catch is a last resort for other load failures (e.g. a corrupt
  // .env): initialize an empty env so MihomoAPI never sees an
  // uninitialized dotenv.
  try {
    await dotenv.load(isOptional: true);
  } catch (_) {
    // Unexpected load failure (e.g. a corrupt .env): initialize an empty
    // env so MihomoAPI never sees an uninitialized dotenv.
    dotenv.loadFromString(isOptional: true);
  }
  final settingsController = AppSettingsController();
  await settingsController.load();
  // Restore the persisted routing backend preference before the first frame,
  // so the settings page and scheduler chip never flash the wrong value.
  await SchedulerWrapper.loadBackendPreference();
  // Restore persisted address-bypass presets before the first frame; the CN
  // CIDR index is prefetched here when the cn preset is enabled.
  await AddressFilterController.loadEnabled();
  // Attach the Rust scheduler when a native library is bundled. A missing
  // dylib (tests, web, older installs) is fine: SchedulerWrapper falls back
  // to its equivalent Dart implementation.
  try {
    await RustLib.init();
  } catch (e) {
    // Native backend unavailable (dylib not built/bundled, web, or a codegen
    // version mismatch). Keep the equivalent Dart scheduler working, but log
    // a readable reason instead of failing completely silently.
    debugPrint('[Ayatsuri] Rust scheduler init failed: $e');
  }
  runApp(MyApp(settingsController: settingsController));
}
