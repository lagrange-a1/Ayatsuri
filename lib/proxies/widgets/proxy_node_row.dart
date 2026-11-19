// Node list row: one Material 3 card for a single proxy node.
//
// Extracted from the page's private node-row builder. Every widget key and
// piece of copy is preserved so widget tests and lookup helpers stay stable.
// All page state is supplied explicitly through typed constructor arguments;
// the widget never reaches back into the parent page's State object.

import 'package:flutter/material.dart';

import 'package:ayatsuri/l10n/app_localizations.dart';

import '../node_label.dart';
import '../proxy_service.dart';

/// A single tappable proxy node card.
///
/// [onNodeTap] and [onProbeTap] are supplied by the parent with the node
/// already bound, so this widget stays stateless and free of page internals.
class ProxyNodeRow extends StatelessWidget {
  const ProxyNodeRow({
    super.key,
    required this.group,
    required this.proxy,
    required this.best,
    required this.devMode,
    required this.probing,
    required this.zh,
    required this.onNodeTap,
    required this.onProbeTap,
  });

  final GroupItem group;
  final ProxyItem proxy;

  /// The currently recommended node name (the page's `_best`).
  final String? best;

  /// Force-select mode: auto-group members are tappable only when true.
  final bool devMode;

  /// Whether this node's single-node probe is in flight.
  final bool probing;

  /// Chinese-vs-English copy selector.
  final bool zh;

  final VoidCallback onNodeTap;
  final VoidCallback onProbeTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isNow = group.now == proxy.name;
    final isRecommended = best == proxy.name && !isNow;
    // Auto-group members are only tappable in force mode; Selector members
    // are always tappable. Neither hides unreachable nodes.
    final canTap = !group.isAuto || devMode;

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
        onTap: canTap ? onNodeTap : null,
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
                              zh ? '推荐' : 'Recommended',
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
                        // Single test control: the delay label itself. The
                        // status dot at the left is the only colour-coded
                        // latency affordance, so no second icon is needed.
                        Tooltip(
                          message: zh ? '点击测速该节点' : 'Tap to test this node',
                          child: InkWell(
                            key: ValueKey('proxy-delay-${proxy.name}'),
                            onTap: canTap ? onProbeTap : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: probing
                                  ? const SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      delayLabel(l10n, proxy.delay),
                                      style: textTheme.labelMedium?.copyWith(
                                        color: scheme.onSurface,
                                        fontWeight: FontWeight.w600,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                            ),
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
