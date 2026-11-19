// lib/info/scheduler_dashboard.dart
//
// Makes the Rust/Dart scheduling core visible: which backend is active, what
// the full ranking looks like for the selected Selector group, a one-tap
// "auto select" that commits the scheduler's non-destructive suggestion, and
// an opt-in background auto-schedule loop that keeps doing it for you.

import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/material.dart';

import '../data/endpoints.dart';
import '../proxies/proxy_service.dart';
import '../proxies/scheduler_wrapper.dart';

/// Inline bilingual helper: new copy stays local to this widget so the l10n
/// generated files do not need to change.
bool _isZh(BuildContext context) =>
    Localizations.maybeLocaleOf(context)?.languageCode == 'zh';

String _tr(BuildContext context, String zh, String en) =>
    _isZh(context) ? zh : en;

/// Compact human age for a rank row's last observation.
String _ageLabel(int ms) =>
    ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';

/// Human-readable native-backend status, read from SchedulerWrapper's public
/// API. The badge must explain *why* the Dart twin is in use instead of
/// claiming "Dart fallback" unconditionally — on Linux the dylib is often
/// simply missing, and the concrete load error is the useful information.
/// Mirrors the settings page's status subtitle so both surfaces agree.
String _backendStatusText(BuildContext context) {
  final status = SchedulerWrapper.rustStatus;
  final pref = SchedulerWrapper.backendPreference;
  switch (status) {
    case RustBackendStatus.initializing:
      return _tr(context, 'Rust 后端初始化中…', 'Rust backend initializing…');
    case RustBackendStatus.available:
      return pref == RoutingBackend.forceDart
          ? _tr(
              context,
              'Rust 已加载，但强制使用 Dart',
              'Rust loaded, but Dart is forced',
            )
          : _tr(context, 'Rust 原生内核已加载', 'Rust native core loaded');
    case RustBackendStatus.unavailable:
      final raw = SchedulerWrapper.rustError;
      final reason = raw == null || raw.isEmpty
          ? _tr(context, '未知原因', 'unknown reason')
          : (raw.length > 120 ? '${raw.substring(0, 120)}…' : raw);
      return _tr(context, 'Rust 不可用：$reason', 'Rust unavailable: $reason');
  }
}

/// Period of the background auto-scheduling loop.
///
/// One cycle probes every member of the current group, so 60 seconds keeps
/// that extra `GET /proxies/:name/delay` traffic modest while still reacting
/// to latency changes within a minute. A named constant gives tests and any
/// future settings screen a single source of truth.
const Duration kAutoSchedulePeriod = Duration(seconds: 60);

/// Dashboard over an injected [ProxySelection].
///
/// Pass [selection] to share the app's observation window; when omitted a
/// fresh one is built over the optional [api]. Groups come only from
/// `selection.selectors` (manual Selector pools): automatic pools have no
/// user-pinnable `now` and are deliberately excluded from the auto-commit.
class SchedulerDashboard extends StatefulWidget {
  const SchedulerDashboard({super.key, this.selection, this.api});

  /// Injectable selection (already loaded or to be loaded on mount).
  final ProxySelection? selection;

  /// Optional controller API, used only when [selection] is not injected.
  final MihomoAPI? api;

  /// The State is public so widget tests can drive one cycle deterministically
  /// via `SchedulerDashboardState.runAutoCycle()` instead of waiting a minute.
  @override
  SchedulerDashboardState createState() => SchedulerDashboardState();
}

class SchedulerDashboardState extends State<SchedulerDashboard> {
  late ProxySelection _selection =
      widget.selection ?? ProxySelection(api: widget.api);

  GroupItem? _group;
  List<NodeRank> _ranks = const <NodeRank>[];
  String? _recommended;
  String? _error;
  bool _ranking = false;
  bool _selecting = false;

  /// Guards the explicit "probe current group" action in the empty state.
  /// Separate from [_ranking] so a one-tap probe cannot be double-submitted.
  bool _probing = false;

  // ── background auto-scheduling ──────────────────────────────────────────
  /// Default OFF: an IndexStack-resident page must be silent until the user
  /// explicitly opts in, so no timer (and therefore no probe) is created here.
  bool _autoEnabled = false;
  Timer? _autoTimer;
  String? _lastAutoNote;

  /// `HH:MM` stamp for the last automated action, shown in the note line.
  String _stamp() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant SchedulerDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selection == oldWidget.selection &&
        widget.api == oldWidget.api) {
      return;
    }
    // A reconfigured/replaced selection must not keep showing the previous
    // one's groups and ranking (the State is reused when the widget type is
    // unchanged).
    _selection = widget.selection ?? ProxySelection(api: widget.api);
    _group = null;
    _recommended = null;
    _ranks = const <NodeRank>[];
    _attach();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _autoTimer = null;
    super.dispose();
  }

  void _attach() {
    _syncGroups();
    if (!_selection.loaded) {
      _selection
          .load()
          .then((_) {
            if (!mounted) return;
            setState(_syncGroups);
            _refreshRanks();
          })
          .catchError((Object e) {
            if (!mounted) return;
            setState(() => _error = e.toString());
          });
    } else {
      _refreshRanks();
    }
  }

  /// Keep [_group] pointing at a currently selectable group. Group objects
  /// are recreated on every load, so identity is compared by name and the
  /// object is always rebound to the freshest snapshot — otherwise `now`
  /// would stay stale after a commit and the next `bestProxy(current:)` would
  /// be computed against the old node.
  void _syncGroups() {
    final groups = _selection.selectors;
    if (groups.isEmpty) {
      _group = null;
      if (_ranks.isNotEmpty) _ranks = const <NodeRank>[];
      return;
    }
    final current = _group;
    if (current == null) {
      _group = groups.first;
      return;
    }
    _group = groups.firstWhere(
      (g) => g.name == current.name,
      orElse: () => groups.first,
    );
  }

  Future<void> _refreshRanks() async {
    final group = _group;
    if (group == null) {
      if (mounted) setState(() => _ranks = const <NodeRank>[]);
      return;
    }
    if (mounted) {
      setState(() {
        _ranking = true;
        _error = null;
      });
    }
    try {
      final rows = await _selection.rankProxies(group.all);
      if (!mounted) return;
      setState(() => _ranks = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _ranking = false);
    }
  }

  /// Probe one node with its own error boundary. A failed node keeps its
  /// previous sample and never aborts the rest of the (concurrent) batch.
  Future<void> _probeOne(String name) async {
    try {
      await _selection.probeByName(name);
    } catch (_) {
      // Same tolerance as the node page's whole-group ping: one bad node
      // must not silently stop the group's measurement.
    }
  }

  /// Explicit, user-initiated group probe used by the empty state to produce
  /// the very first samples. Feeds the *shared* [ProxySelection] (the same one
  /// the auto-schedule loop and auto-select use), so the data lands in the very
  /// scheduler whose ranks are rendered here. Deliberately does NOT call
  /// bestProxy/select — committing a node stays an explicit auto-select tap.
  ///
  /// Probes in concurrent batches of 50, matching the node page's one-click
  /// ping: a 100-node group finishes in ~2 batches instead of ~80 serial
  /// awaits. [_probing] still de-bounces taps and drives the progress spinner.
  Future<void> _probeGroup() async {
    final group = _group;
    if (group == null || _probing) return;
    if (mounted) {
      setState(() {
        _probing = true;
        _error = null;
      });
    }
    final names = List<String>.from(group.all);
    try {
      const batchSize = 50;
      for (var i = 0; i < names.length; i += batchSize) {
        final batch = names.skip(i).take(batchSize);
        await Future.wait<void>(batch.map(_probeOne));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _probing = false);
    }
    if (!mounted) return;
    await _refreshRanks();
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Find a manual Selector that really contains [node]. The current group is
  /// preferred, then any other Selector; automatic pools are never a target
  /// and there is deliberately no `orElse: () => group` fallback — if no
  /// Selector holds the node we skip the PUT entirely.
  GroupItem? _targetFor(String node, GroupItem current) {
    final selectors = _selection.selectors;
    for (final group in selectors) {
      if (group.name == current.name && group.all.contains(node)) return group;
    }
    for (final group in selectors) {
      if (group.all.contains(node)) return group;
    }
    return null;
  }

  Future<void> _autoSelect() async {
    final group = _group;
    if (group == null || _selecting) return;
    setState(() => _selecting = true);

    String? best;
    Object? failure;
    try {
      best = await _selection.bestProxy(
        candidates: group.all,
        current: group.now,
      );
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _selecting = false);
    if (failure != null) {
      _snack(_tr(context, '推荐失败：$failure', 'Recommendation failed: $failure'));
      return;
    }
    if (best == null) {
      _snack(_tr(context, '没有可用推荐', 'No recommendation available'));
      return;
    }

    final picked = best; // promoted for the closures below
    setState(() => _recommended = picked);
    final zh = _isZh(context);
    if (picked == group.now) {
      _snack(zh ? '当前已是最佳节点：$picked' : 'Already on the best node: $picked');
      return;
    }

    final target = _targetFor(picked, group);
    if (target == null) {
      _snack(
        _tr(
          context,
          '没有包含 $picked 的手动代理组，未切换',
          'No manual group contains $picked; nothing switched',
        ),
      );
      return;
    }
    try {
      await _selection.select(target.name, picked);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    if (failure != null) {
      _snack(_tr(context, '选择失败：$failure', 'Select failed: $failure'));
      return;
    }
    _selection.selector.adopt(picked);

    // Refresh controller state so the header's "current" and the next
    // `bestProxy(current: group.now)` use the node we just committed.
    await _selection.load();
    if (!mounted) return;
    setState(() {
      _syncGroups();
      _recommended = picked;
    });
    await _refreshRanks();

    _snack(
      zh ? '已选择 $picked（${target.name}）' : 'Selected $picked in ${target.name}',
    );
  }

  /// One complete background scheduling cycle.
  ///
  /// Public and returning [Future] so a widget test can drive it directly:
  /// probe every candidate, ask for a suggestion with the *real* current
  /// node, and commit only through a Selector that actually contains the
  /// suggestion. Any failure is reported in [_lastAutoNote] + a SnackBar and
  /// swallowed, so a periodic tick can never crash the timer.
  Future<void> runAutoCycle() async {
    final group = _group;
    if (group == null) return;
    final candidates = List<String>.from(group.all);
    try {
      // Fresh delays for every candidate before asking the Rust/Dart core.
      for (final name in candidates) {
        await _selection.probeByName(name);
      }
      final best = await _selection.bestProxy(
        candidates: candidates,
        current: group.now,
      );

      // Nothing to do: no usable node, or we are already on it. Never PUT.
      if (best == null || best == group.now) {
        if (mounted) {
          setState(
            () => _lastAutoNote = _tr(
              context,
              '${_stamp()} 无需切换（自动调度）',
              '${_stamp()} no switch needed (auto)',
            ),
          );
        }
        return;
      }

      // Defensive: only a Selector that really holds `best` may be written.
      final target = _targetFor(best, group);
      if (target == null) {
        if (mounted) {
          setState(
            () => _lastAutoNote = _tr(
              context,
              '${_stamp()} 没有包含 $best 的手动组，跳过（自动调度）',
              '${_stamp()} no manual group contains $best, skipped (auto)',
            ),
          );
        }
        return;
      }

      await _selection.select(target.name, best);
      _selection.selector.adopt(best);
      await _selection.load();
      if (!mounted) return;
      setState(() {
        _syncGroups();
        _recommended = best;
        _lastAutoNote = '${_stamp()} · $best';
      });
      await _refreshRanks();
      if (!mounted) return;
      _snack(
        _tr(
          context,
          '已自动切换到 $best（自动调度）',
          'Auto-switched to $best (auto schedule)',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _lastAutoNote = _tr(
          context,
          '${_stamp()} 自动调度失败：$e',
          '${_stamp()} auto schedule failed: $e',
        ),
      );
      _snack(_tr(context, '自动调度失败：$e', 'Auto schedule failed: $e'));
    }
  }

  void _toggleAuto(bool enabled) {
    setState(() => _autoEnabled = enabled);
    _syncAutoTimer();
  }

  /// Cancel-before-create: toggling on repeatedly, or rebuilding, can never
  /// stack two periodic timers (which would double every probe and PUT).
  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (!_autoEnabled || !mounted) return;
    _autoTimer = Timer.periodic(kAutoSchedulePeriod, (_) {
      unawaited(runAutoCycle());
    });
  }

  void _onGroupChanged(GroupItem? group) {
    if (group == null) return;
    setState(() => _group = group);
    _refreshRanks();
  }

  Widget _rankTile(BuildContext context, NodeRank row, bool lowest, bool zh) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('scheduler-rank-${row.proxy}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: lowest ? scheme.primaryContainer : null,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: lowest ? scheme.primary : Colors.transparent),
      ),
      child: ListTile(
        dense: true,
        title: Row(
          children: [
            Expanded(child: Text(row.proxy, overflow: TextOverflow.ellipsis)),
            if (lowest)
              Chip(
                key: ValueKey('scheduler-lowest-${row.proxy}'),
                visualDensity: VisualDensity.compact,
                label: Text(
                  zh ? '最低分' : 'Lowest',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        subtitle: Wrap(
          spacing: 12,
          runSpacing: 2,
          children: [
            Text('EWMA ${row.ewma.toStringAsFixed(1)}'),
            Text('${zh ? '抖动' : 'Jitter'} ${row.jitter.toStringAsFixed(1)}'),
            Text('${zh ? '评分' : 'Score'} ${row.score.toStringAsFixed(1)}'),
            Text('${zh ? '样本' : 'Samples'} ${row.samples}'),
            Text('${zh ? '失败' : 'Fails'} ${row.failures}'),
            Text(
              '${zh ? '可用' : 'Available'} '
              '${row.available ? (zh ? '是' : 'Yes') : (zh ? '否' : 'No')}',
            ),
            Text('${zh ? '时长' : 'Age'} ${_ageLabel(row.ageMs)}'),
          ],
        ),
      ),
    );
  }

  /// No samples yet: explain why the table is empty and offer the one action
  /// that populates it — probing the currently selected Selector group through
  /// the *shared* selection. Kept compact so it fits the Expanded slot.
  Widget _emptyState(BuildContext context, bool zh, GroupItem? group) {
    final canProbe = group != null && !_probing;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              zh ? '暂无调度样本' : 'No scheduling samples yet',
              key: const ValueKey('scheduler-empty'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              zh
                  ? '测速当前组后将在此显示排名'
                  : 'Probe the current group to build a ranking',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('scheduler-group-probe'),
              onPressed: canProbe ? _probeGroup : null,
              icon: _probing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: Text(
                _probing
                    ? (zh ? '测速中…' : 'Probing…')
                    : (zh ? '测速当前组' : 'Probe current group'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zh = _isZh(context);
    final groups = _selection.selectors;
    final group = _group;
    final lowest = _ranks.isEmpty
        ? null
        : _ranks.map((r) => r.score).reduce(min);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Bind to the public notifier so switching the backend
                    // preference on the settings page rebuilds this chip
                    // immediately, even though this widget lives on another
                    // page and has no setState of its own (P0-2).
                    ValueListenableBuilder<RoutingBackend>(
                      valueListenable:
                          SchedulerWrapper.backendPreferenceNotifier,
                      builder: (context, _, _) {
                        final rust = _selection.selector.scheduler.rustActive;
                        return Chip(
                          key: const ValueKey('scheduler-backend'),
                          avatar: Icon(
                            rust ? Icons.bolt : Icons.healing_outlined,
                            size: 18,
                          ),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 240),
                            child: Text(
                              // When Rust is genuinely active, name it.
                              // Otherwise show the real status/reason from
                              // the public API, which also reflects the
                              // forced-Dart preference.
                              rust
                                  ? (zh ? 'Rust 核心' : 'Rust core')
                                  : _backendStatusText(context),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      },
                    ),
                    const Spacer(),
                    IconButton(
                      key: const ValueKey('scheduler-refresh'),
                      tooltip: zh ? '刷新排名' : 'Refresh ranking',
                      onPressed: _ranking ? null : _refreshRanks,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                // Short legend so raw Rust metrics are readable at a glance.
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _tr(
                      context,
                      '图例：评分越低越好 · EWMA 单位为毫秒',
                      'Legend: lower score is better · EWMA is in ms',
                    ),
                    key: const ValueKey('scheduler-legend'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(zh ? '当前没有可选的代理组' : 'No selectable groups'),
                  )
                else
                  DropdownButton<GroupItem>(
                    key: const ValueKey('scheduler-group'),
                    isExpanded: true,
                    value: group,
                    onChanged: _onGroupChanged,
                    items: [
                      for (final g in groups)
                        DropdownMenuItem<GroupItem>(
                          key: ValueKey('scheduler-group-${g.name}'),
                          value: g,
                          child: Text(
                            '${g.name} · ${g.typeLabel}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${zh ? '当前节点' : 'Current'}: '
                        '${group?.now ?? '-'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${zh ? '推荐节点' : 'Recommended'}: '
                        '${_recommended ?? '-'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                // Opt-in background loop. OFF by default -> no timer, no probe.
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Tooltip(
                        message: _tr(
                          context,
                          '开启后每 60 秒探测一次，并在有更优节点时自动切换；随时可手动覆盖',
                          'Probes every 60 seconds and auto-switches when a '
                              'better node is found; manual picks always win',
                        ),
                        child: Switch(
                          key: const ValueKey('scheduler-auto-schedule-switch'),
                          value: _autoEnabled,
                          onChanged: _toggleAuto,
                        ),
                      ),
                      Text(_tr(context, '自动调度', 'Auto schedule')),
                    ],
                  ),
                ),
                if (_lastAutoNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _lastAutoNote!,
                      key: const ValueKey('scheduler-auto-note'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('scheduler-auto-select'),
                  onPressed: (group == null || _selecting) ? null : _autoSelect,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(zh ? '自动选择' : 'Auto select'),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _ranking
              ? const Center(child: CircularProgressIndicator())
              : _ranks.isEmpty
              ? _emptyState(context, zh, group)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: _ranks.length,
                  itemBuilder: (context, i) {
                    final row = _ranks[i];
                    return _rankTile(context, row, row.score == lowest, zh);
                  },
                ),
        ),
      ],
    );
  }
}
