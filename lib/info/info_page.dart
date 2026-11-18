import 'package:flutter/material.dart';

import '../data/endpoints.dart';
import '../l10n/app_localizations.dart';
import '../proxies/proxy_service.dart';
import 'info_dashboard.dart';
import 'mihomo_info.dart';

class MihomoInfo extends StatefulWidget {
  const MihomoInfo({super.key, required this.api});

  final MihomoAPI api;

  @override
  State<MihomoInfo> createState() => _MihomoInfoState();
}

class _MihomoInfoState extends State<MihomoInfo> {
  late final MihomoAPI _api;
  bool _loading = false;
  bool _pinging = false;
  String? _error;

  // ── Collected data ──────────────────────────────────────────────────
  /// The nine info sections, in display order.
  List<Map<String, dynamic>?> get _sections => [
    _version,
    _configs,
    _proxies,
    _groups,
    _rules,
    _connections,
    _traffic,
    _memory,
    _logs,
  ];

  bool get _hasAnyData => _sections.any((d) => d != null);

  Map<String, dynamic>? _version;
  Map<String, dynamic>? _configs;
  Map<String, dynamic>? _proxies;
  Map<String, dynamic>? _groups;
  Map<String, dynamic>? _rules;
  Map<String, dynamic>? _connections;
  Map<String, dynamic>? _traffic;
  Map<String, dynamic>? _memory;
  Map<String, dynamic>? _logs;

  @override
  void initState() {
    super.initState();
    _api = widget.api;
    // Fetch the controller state as soon as the page starts.
    _fetchEverything();
  }

  Future<void> _fetchEverything() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    // Each endpoint is fetched independently: one slow/flaky endpoint
    // (e.g. the streaming /traffic, /memory, /logs) must not fail the
    // whole page. Transient connection failures are retried every 0.5s
    // in the background and degrade to an empty section; only
    // non-transient failures surface the error page.
    // (fetch, assign) pairs — one table instead of nine near-identical
    // closures.
    final fetchers =
        <(Future<dynamic> Function(), void Function(Map<String, dynamic>))>[
          (_api.getVersion, (d) => _version = d),
          (_api.getConfigs, (d) => _configs = d),
          (_api.getProxies, (d) => _proxies = d),
          (_api.getGroups, (d) => _groups = d),
          (_api.getRules, (d) => _rules = d),
          (_api.getConnections, (d) => _connections = d),
          (_api.getTraffic, (d) => _traffic = d),
          (_api.getMemory, (d) => _memory = d),
          (_api.getLogs, (d) => _logs = d),
        ];

    var pending = fetchers.length;
    for (final (fetch, assign) in fetchers) {
      retryTransient(fetch)
          .then((r) {
            if (r != null) assign(r.data as Map<String, dynamic>);
          })
          .catchError((Object e) {
            // Non-transient failure: remember the first one; the error
            // page only shows when nothing loaded at all.
            _error ??= _formatError(e);
          })
          .whenComplete(() {
            pending--;
            if (mounted) {
              setState(() {
                _loading = pending > 0;
                if (pending == 0 && _version == null && _error != null) {
                  // Keep the error so the page can show it.
                }
              });
            }
          });
    }
  }

  String _formatError(Object e) => e.toString();

  /// One-click ping test for every node (Clash Verge-style): probe each
  /// selector member once with bounded concurrency, then refetch so the
  /// dashboard delays are fresh. Lives on the Info tab — not the globe
  /// (which already probes in the background) and not settings.
  Future<void> _pingAllNodes() async {
    if (_pinging || _loading) return;
    setState(() => _pinging = true);
    var count = 0;
    Object? failure;
    try {
      final selection = ProxySelection(api: _api);
      await selection.load();
      final names = <String>{};
      for (final group in selection.selectors) {
        names.addAll(group.all);
      }
      final list = names.toList();
      // Bounded concurrency so a full sweep does not hammer the core.
      for (var i = 0; i < list.length; i += 16) {
        if (!mounted) return;
        await Future.wait(list.skip(i).take(16).map(selection.probeByName));
        count += list.skip(i).take(16).length;
      }
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _pinging = false);
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failure != null
              ? l10n.pingAllFailed(failure.toString())
              : l10n.pingAllDone(count),
        ),
      ),
    );
    if (failure == null) _fetchEverything();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(l10n.infoTitle),
        actions: [
          IconButton(
            onPressed: (_pinging || _loading) ? null : _pingAllNodes,
            icon: _pinging
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed),
            tooltip: l10n.pingAllNodes,
          ),
          IconButton(
            onPressed: _loading ? null : _fetchEverything,
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: l10n.fetchAll,
          ),
        ],
      ),
      floatingActionButton: _version != null && !_loading
          ? FloatingActionButton(
              onPressed: _fetchEverything,
              tooltip: l10n.fetchAll,
              child: const Icon(Icons.refresh),
            )
          : null,
      // Loading takes precedence over the empty/error states while a fetch
      // is in flight (initial load, nothing to show yet): show a spinner,
      // not the "no data" placeholder. With data already loaded a refresh
      // keeps the dashboard visible underneath.
      body: _version == null && _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _version == null && !_hasAnyData
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: .center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.requestFailed,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                      textAlign: .center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _loading ? null : _fetchEverything,
                      child: Text(l10n.retry),
                    ),
                  ],
                ),
              ),
            )
          : _version == null
          ? Center(
              child: Column(
                mainAxisAlignment: .center,
                children: [
                  const Icon(
                    Icons.storage_outlined,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.noDataYet),
                  const SizedBox(height: 8),
                  Text(l10n.noDataHint, style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _loading ? null : _fetchEverything,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.fetchAllData),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : InfoDashboard(
              summary: MihomoInfoSummary.fromAll(
                version: _version,
                configs: _configs,
                proxies: _proxies,
                group: _groups,
                rules: _rules,
                connections: _connections,
                traffic: _traffic,
                memory: _memory,
                logs: _logs,
              ),
              rawBySection: {
                'version': _version,
                'configs': _configs,
                'proxies': _proxies,
                'groups': _groups,
                'rules': _rules,
                'connections': _connections,
                'traffic': _traffic,
                'memory': _memory,
                'logs': _logs,
              },
            ),
    );
  }
}
