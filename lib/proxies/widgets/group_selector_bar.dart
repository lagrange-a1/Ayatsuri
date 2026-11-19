// Group selection bar: the ChoiceChip Wrap plus the always-visible
// auto-routing explanation. Extracted from the page's build method; all keys
// and copy are preserved verbatim.

import 'package:flutter/material.dart';

import '../proxy_service.dart';

/// Every exposed group as a chip, followed by an always-visible explanation
/// when at least one group is auto-routed by the kernel.
class GroupSelectorBar extends StatelessWidget {
  const GroupSelectorBar({
    super.key,
    required this.groups,
    required this.currentGroupName,
    required this.zh,
    required this.onGroupChanged,
  });

  final List<GroupItem> groups;
  final String? currentGroupName;
  final bool zh;
  final ValueChanged<String> onGroupChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
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
                        Container(
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
                            zh ? '自动' : 'AUTO',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                    ],
                  ),
                  selected: group.name == currentGroupName,
                  onSelected: (_) => onGroupChanged(group.name),
                ),
            ],
          ),
        ),
        // ── Auto-route explanation: always visible, never tooltip-only ────
        if (groups.any((g) => g.isAuto))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Text(
              zh
                  ? '部分组由内核自动选路，手动选择可能无效'
                  : 'Some groups are auto-routed by the kernel; manual picks may not apply',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
