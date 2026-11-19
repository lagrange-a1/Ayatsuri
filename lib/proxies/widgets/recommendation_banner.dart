// Recommendation status banner: the 建议/Recommendation line with its
// tri-state text, the optional poll-timeout note and the technical
// (proxy-best-technical) row. Extracted from the page's status-line builder;
// every key and string is preserved verbatim.

import 'package:flutter/material.dart';

import '../scheduler_wrapper.dart';

/// Text status line for the recommendation, making all three states
/// distinguishable without relying on the single-bit recommendation badge.
class RecommendationBanner extends StatelessWidget {
  const RecommendationBanner({
    super.key,
    required this.state,
    required this.pollFailed,
    required this.bestRank,
    required this.isSuggestSwitch,
    required this.zh,
  });

  /// Precomputed tri-state text: "no samples", "current is best", or a
  /// "switch to" a target node as a call to action.
  final String state;

  /// True when the bounded current-node poll exhausted without resolving.
  final bool pollFailed;

  /// Technical basis for the suggested node, when rank data is available.
  final NodeRank? bestRank;

  /// Whether the current tri-state is the "suggest switch" state.
  final bool isSuggestSwitch;

  final bool zh;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final rank = bestRank;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                zh ? '建议' : 'Recommendation',
                style: textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                state,
                key: const ValueKey('proxy-best-state'),
                style: textTheme.bodySmall,
              ),
            ],
          ),
          if (pollFailed)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                zh
                    ? '当前节点状态暂不可用（获取超时）'
                    : 'Current node unavailable (poll timed out)',
                key: const ValueKey('proxy-poll-timeout'),
                style: textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          // ── Technical basis: separate register, same page ─────────────
          if (rank != null && isSuggestSwitch)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                zh
                    ? '延迟 ${rank.ewma.toStringAsFixed(0)}ms  │  '
                          '抖动 ${rank.jitter.toStringAsFixed(0)}ms  │  '
                          '失败 ${rank.failures} 次'
                    : 'Latency ${rank.ewma.toStringAsFixed(0)}ms  │  '
                          'Jitter ${rank.jitter.toStringAsFixed(0)}ms  │  '
                          'Failures ${rank.failures}',
                key: const ValueKey('proxy-best-technical'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
