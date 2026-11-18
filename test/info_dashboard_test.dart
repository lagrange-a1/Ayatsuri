import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayatsuri/info/info_dashboard.dart';
import 'package:ayatsuri/info/mihomo_info.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';

void main() {
  testWidgets('diagnostics are collapsed by default but reachable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: InfoDashboard(
            summary: MihomoInfoSummary.fromAll(),
            rawBySection: const {},
          ),
        ),
      ),
    );

    final tile = find.byKey(const ValueKey('info-diagnostics'));
    expect(tile, findsOneWidget);
    final expansion = tester.widget<ExpansionTile>(tile);
    expect(expansion.initiallyExpanded, isFalse);
    final title = expansion.title as Text;
    expect(title.data, anyOf('More diagnostics', '更多诊断信息'));

    // The dev panels are one tap away, not deleted.
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<ExpansionTile>(tile).initiallyExpanded, isFalse);
    expect(tile, findsOneWidget);
  });
}
