import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/main.dart';

void main() async {
  // `main()` is not called by the widget test, so dotenv must be loaded
  // inside the test body (the binding already exists there).
  testWidgets('App has a globe page and a five-item bottom navigation bar', (
    WidgetTester tester,
  ) async {
    dotenv.loadFromString(envString: 'host=localhost\nport=9091\nsecret=***\n');
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // The globe page is now the home tab; it fetches proxies and groups on
    // startup. In widget tests there is no WebView platform implementation,
    // so the page renders its placeholder instead of the real WebView.
    expect(find.text('Select a node · Globe'), findsOneWidget);
    expect(find.text('Globe (3D unavailable in tests)'), findsOneWidget);
    expect(find.text('Tap a Country/Region'), findsOneWidget);

    // Five fixed tabs in order: globe, nodes, schedule, info, settings.
    final nav = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(nav.type, BottomNavigationBarType.fixed);
    expect(nav.items.length, 5);
    expect(find.byIcon(Icons.public), findsOneWidget);
    expect(find.byIcon(Icons.dns), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.info), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    // Nodes tab mounts the standalone list selector. IndexedStack keeps
    // offstage tabs out of the finder, so these keys appear only once the
    // tab is selected.
    await tester.tap(find.byIcon(Icons.dns));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-refresh')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-dev-switch')), findsOneWidget);
    expect(find.text('Select a node · Globe'), findsNothing);

    // Schedule tab mounts the Rust/Dart dashboard.
    await tester.tap(find.byIcon(Icons.schedule));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scheduler-backend')), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-auto-select')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-refresh')), findsNothing);

    // The info tab also fetches on startup; the error state is environment
    // dependent (9091 is auth-gated here), so any rendered article state is
    // accepted.
    await tester.tap(find.byIcon(Icons.info));
    // Pump and settle clears the timers created by the startup fetches,
    // otherwise the framework complains about pending timers after the widget
    // tree is disposed.
    await tester.pumpAndSettle();
    expect(find.text('Ayatsuri · Mihomo Info'), findsOneWidget);
    expect(find.byKey(const ValueKey('scheduler-backend')), findsNothing);
  });
}
