// Process entrypoint only: await the explicit bootstrap, then run the app.
// The ordered startup phases live in app/bootstrap.dart; the app shell lives
// in app.dart. Both MyApp and MihomoApp stay exported from here for tests.
import 'package:flutter/material.dart';

import 'app.dart';
import 'app/bootstrap.dart';

export 'app.dart';

Future<void> main() async {
  final services = await bootstrap();
  runApp(MyApp(services: services));
}
