/*
 * FlClash-style list proxy picker, independent of the globe page.
 *
 * A top group selector lists every group the model exposes (`allGroups`,
 * Selectors *and* automatic pools). Picking a group rebuilds the row list
 * from `nodesForGroup`, which deliberately keeps unreachable nodes visible.
 * Each row shows a compacted label, the last probe delay, a check mark for
 * the group's current node and a recommendation badge for the node the
 * scheduler suggests. Automatic groups are read-only by default; a page-local
 * "force-select auto groups" switch unlocks `selectAny` on them for advanced
 * probing (the kernel may reject it).
 *
 * All new copy is hand-written bilingual (see `_zh`); no generated l10n keys
 * are added.
 */

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';

import 'node_label.dart';
import 'proxy_service.dart';

/// A standalone list-style proxy selector.
///
/// [api] is used only when no [selection] is injected (production). Tests
/// inject a [ProxySelection] to control the data and record node taps.
class ProxyListPage extends StatefulWidget {
  const ProxyListPage({super.key, required this.api, ProxySelection? selection})
    : _injectedSelection = selection;

  final MihomoAPI api;
  final ProxySelection? _injectedSelection;

  @override
  State<ProxyListPage> createState() => _ProxyListPageState();
}

class _ProxyListPageState extends State<ProxyListPage> {
  late final ProxySelection _selection;

  bool _loading = true;
  String? _error;
  String? _currentGroupName;
  bool _devMode = false;
  String? _best;

  /// Bumped on every load / group switch. `_computeBest` writes the shared
  /// [_best] only while its captured generation is still current, so a slow
  /// answer for an old group can never paint a badge on the new group.
  int _generation = 0;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  @override
  void initState() {
    super.initState();
    _selection = widget._injectedSelection ?? ProxySelection(api: widget.api);
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _best = null;
    });
    await _selection.load();
    if (!mounted) return;
    // The fetched snapshot is global, so a stale generation may still finish
    // the loading state; only group-specific fields are generation-guarded.
    if (generation == _generation) {
      final groups = _selection.allGroups;
      if (_currentGroupName == null ||
          !groups.any((g) => g.name == _currentGroupName)) {
        _currentGroupName = groups.isNotEmpty ? groups.first.name : null;
      }
    }
    // Render the freshly loaded groups/nodes immediately: a slow (or never
    // returning) bestProxy answer must not hold the list hostage.
    setState(() {});
    await _computeBest(generation);
    if (!mounted) return;
    setState(() {
      if (generation == _generation) _error = _selection.error;
      _loading = false;
    });
  }

  /// Non-destructively ask the model which node it would pick in the
  /// currently shown group. A failure must never break the list, so any
  /// error is swallowed and simply leaves the badge hidden.
  ///
  /// Only the [generation] that requested this computation is allowed to
  /// publish its result (P1 race fix).
  Future<void> _computeBest(int generation) async {
    final name = _currentGroupName;
    if (name == null) {
      if (mounted && generation == _generation) {
        setState(() => _best = null);
      }
      return;
    }
    final candidates = _selection.nodesForGroup(name).map((p) => p.name);
    String? suggestion;
    try {
      suggestion = await _selection.bestProxy(candidates: candidates);
    } catch (_) {
      suggestion = null;
    }
    if (!mounted || generation != _generation) return;
    _best = suggestion;
    setState(() {});
  }

  void _onGroupChanged(String name) {
    final generation = ++_generation;
    setState(() {
      _currentGroupName = name;
      _best = null;
    });
    _computeBest(generation);
  }

  Future<void> _onNodeTap(ProxyItem proxy) async {
    final groupName = _currentGroupName;
    if (groupName == null) return;
    final group = _selection.allGroups.where((g) => g.name == groupName);
    if (group.isEmpty) return;
    final isAuto = group.first.isAuto;
    try {
      if (isAuto) {
        await _selection.selectAny(groupName, proxy.name);
      } else {
        await _selection.select(groupName, proxy.name);
      }
    } catch (e) {
      if (!mounted) return;
      _showError(e);
    }
  }

  /// Turns a thrown selection error into one readable, localized snackbar.
  void _showError(Object e) {
    final zh = _zh;
    String reason;
    if (e is DioException) {
      reason = switch (classifyDioError(e)) {
        MihomoErrorKind.auth => zh ? '鉴权失败' : 'Authentication failed',
        MihomoErrorKind.notFound => zh ? '未找到该组' : 'Group not found',
        MihomoErrorKind.badRequest =>
          zh ? '内核拒绝了该操作' : 'Kernel rejected the request',
        MihomoErrorKind.connection => zh ? '无法连接控制器' : 'Controller unreachable',
        MihomoErrorKind.timeout => zh ? '请求超时' : 'Request timed out',
        MihomoErrorKind.unavailable => zh ? '节点不可用' : 'Node unavailable',
        MihomoErrorKind.gatewayTimeout => zh ? '探测超时' : 'Probe timed out',
        MihomoErrorKind.cancelled => zh ? '已取消' : 'Cancelled',
        MihomoErrorKind.badCertificate => zh ? '证书错误' : 'Bad certificate',
        MihomoErrorKind.other => e.message ?? e.toString(),
      };
    } else {
      reason = e.toString();
    }
    final text = zh ? '选择失败：$reason' : 'Selection failed: $reason';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text, key: const ValueKey('proxy-select-error'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _selection.allGroups;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Top group selector: every group, including auto pools ──────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final group in groups)
                ChoiceChip(
                  key: ValueKey('proxy-group-${group.name}'),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(group.name),
                      if (group.isAuto)
                        Tooltip(
                          message: _zh
                              ? '自动组由内核选择节点，手动选择通常会被忽略；开启下方开关可强制尝试'
                              : 'Auto groups pick their node in the kernel; '
                                    'manual picks are normally ignored. Use the '
                                    'switch below to force an attempt.',
                          child: Container(
                            key: ValueKey('proxy-auto-badge-${group.name}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.tertiaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _zh ? '自动' : 'AUTO',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ),
                    ],
                  ),
                  selected: group.name == _currentGroupName,
                  onSelected: (_) => _onGroupChanged(group.name),
                ),
            ],
          ),
        ),
        // ── Force-select switch + refresh ──────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Tooltip(
                message: _zh
                    ? '自动组的节点通常由内核挑选。开启后点击节点会强制向内核发送选择请求，内核可能拒绝。仅用于调试。'
                    : 'Auto-group nodes are normally chosen by the kernel. '
                          'When on, tapping a node force-sends a select request '
                          'that the kernel may reject. For debugging only.',
                child: Switch(
                  key: const ValueKey('proxy-dev-switch'),
                  value: _devMode,
                  onChanged: (v) => setState(() => _devMode = v),
                ),
              ),
              Text(_zh ? '强制选择自动组' : 'Force-select auto groups'),
              const Spacer(),
              IconButton(
                key: const ValueKey('proxy-refresh'),
                tooltip: _zh ? '刷新' : 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _load,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── Loading / empty / node rows ────────────────────────────────
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: ValueKey('proxy-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final groups = _selection.allGroups;
    if (groups.isEmpty) {
      final message = _error != null
          ? (_zh ? '加载失败：$_error' : 'Load failed: $_error')
          : (_zh ? '没有可用节点' : 'No proxies available');
      return Center(
        key: const ValueKey('proxy-empty'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
    }
    final nodes = _selection.nodesForGroup(_currentGroupName!);
    if (nodes.isEmpty) {
      return Center(
        key: const ValueKey('proxy-empty'),
        child: Text(_zh ? '该组暂无节点' : 'No nodes in this group'),
      );
    }
    final group = groups.firstWhere((g) => g.name == _currentGroupName);
    return ListView.builder(
      itemCount: nodes.length,
      itemBuilder: (context, index) => _buildNodeRow(group, nodes[index]),
    );
  }

  Widget _buildNodeRow(GroupItem group, ProxyItem proxy) {
    final l10n = AppLocalizations.of(context);
    final isNow = group.now == proxy.name;
    final isRecommended = _best == proxy.name && !isNow;
    // Auto-group members are only tappable in force mode; Selector members
    // are always tappable. Neither hides unreachable nodes.
    final canTap = !group.isAuto || _devMode;
    return ListTile(
      key: ValueKey('proxy-node-${proxy.name}'),
      // Selected state is visible at a glance even in a long list.
      selected: isNow,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.35),
      leading: CircleAvatar(
        radius: 5,
        backgroundColor: delayColor(proxy.delay),
      ),
      title: Text(
        cleanNodeLabel(proxy.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(delayLabel(l10n, proxy.delay)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isRecommended)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                key: ValueKey('proxy-recommended-${proxy.name}'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _zh ? '推荐' : 'Recommended',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          if (isNow)
            Icon(
              Icons.check,
              key: ValueKey('proxy-current-${proxy.name}'),
              color: Theme.of(context).colorScheme.primary,
            ),
        ],
      ),
      onTap: canTap ? () => _onNodeTap(proxy) : null,
    );
  }
}
