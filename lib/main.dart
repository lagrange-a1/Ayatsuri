import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
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
  runApp(MyApp(settingsController: settingsController));
}
