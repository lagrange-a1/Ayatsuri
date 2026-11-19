/*
 * FlClash-style list proxy picker, independent of the globe page.
 *
 * A top group selector lists every group the model exposes (`allGroups`,
 * Selectors *and* automatic pools). Picking a group rebuilds the row list
 * from `nodesForGroup`, which deliberately keeps unreachable nodes visible.
 * Each row is a Material 3 card showing a compacted label, the group policy
 * tag, a color-coded (tappable) delay, a check mark for the group's current
 * node and a recommendation badge for the node the scheduler suggests.
 *
 * The recommendation defaults to the current node so it is never empty when
 * the scheduler has no samples: a bounded poll resolves an unknown `now`,
 * `bestProxy` is always given that node as its anchor, and only a real,
 * different suggestion overrides the default. Tapping a node's delay probes
 * just that node (no startup sweep), then refreshes and recomputes.
 *
 * A segmented control switches between the node list and an embedded
 * SchedulerDashboard that shares this page's ProxySelection, so observations
 * made here are visible to the scheduler and vice versa.
 *
 * All new copy is hand-written bilingual (see `_zh`); no generated l10n keys
 * are added.
 */

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:ayatsuri/data/endpoints.dart';
import 'package:ayatsuri/info/scheduler_dashboard.dart';
import 'package:ayatsuri/l10n/app_localizations.dart';

import 'node_label.dart';
import 'proxy_service.dart';

/// Recommendation status shown as explicit text in the node view. A single
/// recommendation badge cannot distinguish "no samples yet" from "current node
/// is already best", so the page tracks three states instead of one bit.
enum _BestState { noData, currentIsBest, suggestSwitch }

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
  /// Bounded poll for a group whose `now` is not known yet: at most this many
  /// attempts, each separated by [kCurrentPollInterval] (~15 per second).
  /// Eight attempts (~0.5s) keep a delayed `now` from stalling the list without
  /// a long silent wait; exhausting them surfaces a visible status line.
  static const int kMaxCurrentPolls = 8;
  static const Duration kCurrentPollInterval = Duration(milliseconds: 67);

  late final ProxySelection _selection;

  bool _loading = true;
  String? _error;
  String? _currentGroupName;
  bool _devMode = false;

  /// Never cleared to null by a late/failed recommendation: it holds either
  /// the current node (default) or a real, different scheduler suggestion.
  String? _best;

  /// Explicit tri-state backing the text status line in the node view, so
  /// "no data" and "current node is best" are not conflated behind one badge.
  _BestState _bestState = _BestState.noData;

  /// Set when the bounded poll exhausts without ever resolving `now`; shown
  /// as a short visible status line instead of failing silently.
  bool _pollFailed = false;

  /// false = node list, true = embedded scheduler view.
  bool _showScheduler = false;

  /// Nodes whose single-node probe is in flight (shows a spinner, blocks
  /// duplicate taps).
  final Set<String> _probing = <String>{};

  /// Bumped on every load / group switch / probe. Recommendation work writes
  /// the shared [_best] only while its captured generation is still current,
  /// so a stale answer can never paint a badge on a different group.
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
      _pollFailed = false;
    });
    await _selection.load();
    if (!mounted) return;
    if (generation == _generation) {
      final groups = _selection.allGroups;
      if (_currentGroupName == null ||
          !groups.any((g) => g.name == _currentGroupName)) {
        _currentGroupName = groups.isNotEmpty ? groups.first.name : null;
      }
      // Seed the default immediately: if bestProxy is slow, returns null or
      // throws, the badge still degrades to "stay on current" instead of blank.
      final seed = _currentNodeFor(_currentGroupName);
      if (seed != null) _best = seed;
    }
    // Render the freshly loaded list before waiting on bestProxy (which may
    // briefly poll for an unknown `now`): a slow recommendation never holds
    // the list hostage.
    if (!mounted) return;
    setState(() {
      if (generation == _generation) _error = _selection.error;
      _loading = false;
    });
    await _computeBest(generation);
  }

  /// Resolve the real current node name for [name] from the freshest groups.
  /// A nested-group `now` is still a usable anchor for bestProxy, so only a
  /// null/empty value is treated as unknown.
  String? _currentNodeFor(String? name) {
    if (name == null) return null;
    for (final group in _selection.allGroups) {
      if (group.name == name) {
        final now = group.now;
        return (now == null || now.isEmpty) ? null : now;
      }
    }
    return null;
  }

  /// Bounded poll for a group whose `now` is not published yet. Re-reads the
  /// controller a small fixed number of times so a mid-update `now` settles;
  /// every await is generation/mount guarded and the loop has a hard cap.
  Future<String?> _pollCurrentNode(String name, int generation) async {
    for (var attempt = 0; attempt < kMaxCurrentPolls; attempt++) {
      if (!mounted || generation != _generation) return null;
      await Future<void>.delayed(kCurrentPollInterval);
      if (!mounted || generation != _generation) return null;
      try {
        await _selection.load();
      } catch (_) {
        // A transient load failure must not abort the bounded poll.
      }
      if (!mounted || generation != _generation) return null;
      final now = _currentNodeFor(name);
      if (now != null) {
        setState(() {
          if (generation == _generation) _best = now;
        });
        return now;
      }
    }
    return null;
  }

  /// Non-destructively ask the model which node it would pick in the
  /// currently shown group. The current node is always passed as the anchor;
  /// a null/erroneous answer never erases a non-empty default.
  ///
  /// Only the [generation] that requested this computation is allowed to
  /// publish its result (stale-answer guard).
  Future<void> _computeBest(int generation) async {
    final name = _currentGroupName;
    if (name == null) return;

    var current = _currentNodeFor(name);
    if (current == null) {
      current = await _pollCurrentNode(name, generation);
      if (!mounted || generation != _generation) return;
      // Exhausting the bounded poll is now visible instead of silent.
      setState(() => _pollFailed = current == null);
    } else if (_pollFailed) {
      setState(() => _pollFailed = false);
    }
    if (!mounted || generation != _generation) return;

    final candidates = _selection
        .nodesForGroup(name)
        .map((p) => p.name)
        .toList();
    String? suggestion;
    try {
      suggestion = await _selection.bestProxy(
        candidates: candidates,
        current: current,
      );
    } catch (_) {
      suggestion = null;
    }
    if (!mounted || generation != _generation) return;
    // Publish an explicit tri-state, not just a 1-bit badge:
    //  - null/error (no samples) -> "no data"
    //  - suggestion == current   -> "current is best"
    //  - a real, different node  -> "suggest switch" (and paint its badge).
    if (suggestion != null && suggestion.isNotEmpty && suggestion != current) {
      _best = suggestion;
      _bestState = _BestState.suggestSwitch;
    } else if (suggestion == null || suggestion.isEmpty) {
      _bestState = _BestState.noData;
    } else {
      _bestState = _BestState.currentIsBest;
    }
    setState(() {});
  }

  void _onGroupChanged(String name) {
    // Re-tapping the already-selected chip must not bump generation or fire
    // another bestProxy/HTTP request.
    if (name == _currentGroupName) return;
    final generation = ++_generation;
    setState(() {
      _currentGroupName = name;
      // Keep a non-empty default for the new group when `now` is known;
      // otherwise the bounded poll in _computeBest resolves it.
      _best = _currentNodeFor(name);
      _bestState = _BestState.noData;
      _pollFailed = false;
    });
    _computeBest(generation);
  }

  /// Tap-to-test on a node's delay: probe only this node, then refresh the
  /// delay and recompute the recommendation with the fresh sample. There is
  /// deliberately no automatic whole-group sweep on load.
  Future<void> _onProbeTap(ProxyItem proxy) async {
    if (!_probing.add(proxy.name)) return;
    setState(() {});
    final generation = ++_generation;
    try {
      await _selection.probeByName(proxy.name);
    } catch (_) {
      // A failed probe must not clear the default or break the list.
    }
    if (!mounted) return;
    _probing.remove(proxy.name);
    setState(() {});
    await _computeBest(generation);
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
      // Match the scheduler's "manual picks always win" tooltip: a successful
      // manual pick becomes the hysteresis anchor so auto cycles cannot
      // silently override it. Failures keep the existing snackbar feedback.
      _selection.selector.adopt(proxy.name);
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
              for (final group in _selection.allGroups)
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
        // ── M3 segmented switch: node list vs embedded scheduler ───────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: SegmentedButton<int>(
            key: const ValueKey('proxy-view-switch'),
            segments: <ButtonSegment<int>>[
              ButtonSegment<int>(
                value: 0,
                icon: const Icon(Icons.list_alt),
                label: Text(_zh ? '节点' : 'Nodes'),
                tooltip: _zh ? '查看节点列表' : 'View the node list',
              ),
              ButtonSegment<int>(
                value: 1,
                icon: const Icon(Icons.auto_awesome),
                label: Text(_zh ? '调度' : 'Schedule'),
                tooltip: _zh
                    ? '查看调度排名与自动调度'
                    : 'View scheduling ranks and auto-schedule',
              ),
            ],
            selected: <int>{_showScheduler ? 1 : 0},
            onSelectionChanged: (selected) {
              setState(
                () =>
                    _showScheduler = selected.isNotEmpty && selected.first == 1,
              );
            },
          ),
        ),
        const Divider(height: 1),
        // ── Loading / empty / node rows, or the embedded scheduler ─────
        Expanded(
          child: _showScheduler
              ? SchedulerDashboard(selection: _selection, api: widget.api)
              : _buildBody(),
        ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBestStatusLine(),
        Expanded(
          child: ListView.builder(
            itemCount: nodes.length,
            itemBuilder: (context, index) => _buildNodeRow(group, nodes[index]),
          ),
        ),
      ],
    );
  }

  /// Text status line for the recommendation, making all three states
  /// distinguishable without relying on the single-bit recommendation badge.
  Widget _buildBestStatusLine() {
    final String message;
    switch (_bestState) {
      case _BestState.noData:
        message = _zh ? '推荐状态：暂无观测数据' : 'Recommendation: no data yet';
      case _BestState.currentIsBest:
        message = _zh
            ? '推荐状态：当前节点已是最佳'
            : 'Recommendation: current node is best';
      case _BestState.suggestSwitch:
        final target = _best ?? '-';
        message = _zh
            ? '推荐状态：建议切换到 $target'
            : 'Recommendation: switch to $target';
    }
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            key: const ValueKey('proxy-best-state'),
            style: textTheme.bodySmall,
          ),
          if (_pollFailed)
            Text(
              _zh
                  ? '当前节点状态暂不可用（获取超时）'
                  : 'Current node unavailable (poll timed out)',
              key: const ValueKey('proxy-poll-timeout'),
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNodeRow(GroupItem group, ProxyItem proxy) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isNow = group.now == proxy.name;
    final isRecommended = _best == proxy.name && !isNow;
    // Auto-group members are only tappable in force mode; Selector members
    // are always tappable. Neither hides unreachable nodes.
    final canTap = !group.isAuto || _devMode;
    final probing = _probing.contains(proxy.name);

    return Card(
      key: ValueKey('proxy-node-${proxy.name}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: isNow ? scheme.primaryContainer : null,
      surfaceTintColor: Colors.transparent,
      elevation: isNow ? 2 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isNow
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: canTap ? () => _onNodeTap(proxy) : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Status dot is colored by the last probe result.
              Container(
                key: ValueKey('proxy-delay-dot-${proxy.name}'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: delayColor(proxy.delay),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            cleanNodeLabel(proxy.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleMedium,
                          ),
                        ),
                        if (isRecommended)
                          Container(
                            key: ValueKey('proxy-recommended-${proxy.name}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _zh ? '推荐' : 'Recommended',
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        // Group policy tag, e.g. SELECT / AUTO / FALLBACK.
                        Container(
                          key: ValueKey('proxy-type-${proxy.name}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            group.typeLabel,
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Tap-to-test: probe just this node, then recompute.
                        InkWell(
                          key: ValueKey('proxy-delay-${proxy.name}'),
                          onTap: canTap ? () => _onProbeTap(proxy) : null,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (probing)
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                Icon(
                                  Icons.speed,
                                  size: 13,
                                  color: delayColor(proxy.delay),
                                ),
                              const SizedBox(width: 4),
                              Text(
                                probing
                                    ? (_zh ? '测试中' : 'Testing')
                                    : delayLabel(l10n, proxy.delay),
                                style: textTheme.labelMedium?.copyWith(
                                  color: delayColor(proxy.delay),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isNow)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check_circle,
                    key: ValueKey('proxy-current-${proxy.name}'),
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
