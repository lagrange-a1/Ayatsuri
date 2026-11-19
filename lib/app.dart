import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/endpoints.dart';
import 'globe/globe_map_page.dart';
import 'info/info_page.dart';
import 'l10n/app_localizations.dart';
import 'proxies/proxy_list_page.dart';
import 'settings/app_settings.dart';
import 'settings/settings_page.dart';

/// Nav labels for tabs that have no generated l10n key yet. Follows the
/// repo's hand-written bilingual pattern (see settings_page.dart) so the
/// generated l10n files stay untouched.
bool _navZh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

class MyApp extends StatelessWidget {
  MyApp({super.key, AppSettingsController? settingsController})
    : _controller = settingsController ?? AppSettingsController();

  final AppSettingsController _controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final s = _controller.settings;
        return MaterialApp(
          title: 'ayatsuri',
          locale: s.locale.flutterLocale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          themeMode: s.themeMode,
          theme: buildAppTheme(s, Brightness.light),
          darkTheme: buildAppTheme(s, Brightness.dark),
          builder: (context, child) {
            // Overlay the in-app text-scale factor on top of the system
            // text scale instead of replacing it (the old code overwrote
            // the user's accessibility setting entirely). A factor of 1.0
            // passes the system scaler through untouched.
            final mq = MediaQuery.of(context);
            if (s.textScale == 1.0) return child!;
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(
                  mq.textScaler.scale(1.0) * s.textScale,
                ),
              ),
              child: child!,
            );
          },
          home: MihomoApp(settingsController: _controller),
        );
      },
    );
  }
}

/// Bottom-navigation shell wrapping the system info page and the proxy map page.
class MihomoApp extends StatefulWidget {
  const MihomoApp({super.key, required this.settingsController});

  final AppSettingsController settingsController;

  @override
  State<MihomoApp> createState() => _MihomoAppState();
}

class _MihomoAppState extends State<MihomoApp> {
  int _index = 0;
  late final MihomoAPI _api;

  /// Identity of the controller endpoint currently in use; the data pages
  /// are keyed by it so a settings change rebuilds them (refetching).
  late String _connKey;

  static String _keyOf(AppSettings s) => '${s.serverUrl}|${s.secret}';

  @override
  void initState() {
    super.initState();
    final s = widget.settingsController.settings;
    _api = MihomoAPI(baseUrl: s.serverUrl, secret: s.secret);
    _connKey = _keyOf(s);
    widget.settingsController.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    final key = _keyOf(widget.settingsController.settings);
    if (key == _connKey) return;
    _connKey = key;
    final s = widget.settingsController.settings;
    _api.reconfigure(baseUrl: s.serverUrl, secret: s.secret);
    setState(() {});
  }

  @override
  void dispose() {
    widget.settingsController.removeListener(_onSettingsChanged);
    _api.dio.close();
    super.dispose();
  }

  /// Globe stays the home tab; every data page is keyed by the connection
  /// identity so switching endpoints rebuilds it (and refetches). Tabs in
  /// order: globe, nodes, info, settings. Scheduling is embedded in the
  /// nodes page, so it has no standalone tab.
  List<Widget> get pages => [
    GlobeMapPage(
      key: ValueKey('globe$_connKey'),
      api: _api,
      settingsController: widget.settingsController,
    ),
    ProxyListPage(key: ValueKey('nodes$_connKey'), api: _api),
    MihomoInfo(key: ValueKey('info$_connKey'), api: _api),
    SettingsPage(
      key: ValueKey('settings$_connKey'),
      controller: widget.settingsController,
      api: _api,
    ),
  ];

  List<BottomNavigationBarItem> items(AppLocalizations l10n, bool zh) => [
    BottomNavigationBarItem(
      icon: const Icon(Icons.public, size: 28),
      label: l10n.navGlobe,
    ),
    BottomNavigationBarItem(
      icon: const Icon(Icons.dns, size: 28),
      label: zh ? '节点' : 'Nodes',
    ),
    BottomNavigationBarItem(
      icon: const Icon(Icons.info, size: 28),
      label: l10n.navInfo,
    ),
    BottomNavigationBarItem(
      icon: const Icon(Icons.settings, size: 28),
      label: l10n.navSettings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: items(AppLocalizations.of(context), _navZh(context)),
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
