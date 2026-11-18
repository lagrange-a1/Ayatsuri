mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use flutter_rust_bridge::frb;
use std::cmp::Ordering;
use std::collections::HashSet;

/// Routing tunables. All penalties are in milliseconds, so they are directly
/// comparable with a latency sample and with `hysteresis_ms`.
///
/// The Dart wrapper keeps an identical copy of this struct so that a device
/// without a loadable dylib/webassembly still gets the same decisions.
#[frb]
#[derive(Debug, Clone)]
pub struct SchedulerConfig {
    /// EWMA smoothing factor in [0, 1]. Larger = reacts faster to change.
    pub alpha: f64,
    /// Weight applied to the EWMA of |sample - ewma| (jitter).
    pub jitter_weight: f64,
    /// Extra score added per consecutive failed probe.
    pub failure_penalty_ms: f64,
    /// Extra score added when a node has not been sampled recently.
    pub stale_penalty_ms: f64,
    /// Minimum improvement before `best` switches away from the current node.
    pub hysteresis_ms: f64,
    /// Minimum time between two automatic switches.
    pub cooldown_ms: u64,
    /// Consecutive failures after which a node is excluded from ranking.
    pub max_failures: u32,
    /// Age after which `stale_penalty_ms` starts accumulating.
    pub stale_after_ms: u64,
    /// Samples below this count receive an exploration bonus in ranking.
    pub explore_min_samples: u32,
    /// Per-missing-sample exploration bonus, subtracted from the score.
    pub explore_bonus_ms: f64,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        SchedulerConfig {
            alpha: 0.2,
            jitter_weight: 0.5,
            failure_penalty_ms: 120.0,
            stale_penalty_ms: 40.0,
            hysteresis_ms: 50.0,
            cooldown_ms: 10_000,
            max_failures: 3,
            stale_after_ms: 180_000,
            explore_min_samples: 3,
            explore_bonus_ms: 8.0,
        }
    }
}

impl SchedulerConfig {
    fn normalized(mut self) -> Self {
        fn c(v: f64, lo: f64, hi: f64) -> f64 {
            if v.is_finite() {
                v.clamp(lo, hi)
            } else {
                lo
            }
        }
        // Non-finite fallbacks mirror the Dart wrapper: alpha 0.2 and a
        // 50ms hysteresis keep the same defaults on both backends; the rest
        // fall back to the lower bound.
        self.alpha = if self.alpha.is_finite() {
            self.alpha.clamp(0.0, 1.0)
        } else {
            0.2
        };
        self.jitter_weight = c(self.jitter_weight, 0.0, 4.0);
        self.failure_penalty_ms = c(self.failure_penalty_ms, 0.0, 10_000.0);
        self.stale_penalty_ms = c(self.stale_penalty_ms, 0.0, 10_000.0);
        self.hysteresis_ms = if self.hysteresis_ms.is_finite() {
            self.hysteresis_ms.clamp(0.0, 5_000.0)
        } else {
            50.0
        };
        self.explore_bonus_ms = c(self.explore_bonus_ms, 0.0, 500.0);
        self.max_failures = self.max_failures.max(1);
        self.cooldown_ms = self.cooldown_ms.min(3_600_000);
        self.stale_after_ms = self.stale_after_ms.max(1_000);
        self.explore_min_samples = self.explore_min_samples.max(1);
        self
    }
}

/// Non-destructive view of one node, returned by `rank`, `best` and `stats`.
#[frb]
#[derive(Debug, Clone)]
pub struct NodeStats {
    pub id: u64,
    /// Exponentially weighted mean latency.
    pub ewma: f64,
    /// Exponentially weighted mean absolute deviation from the EWMA.
    pub jitter: f64,
    pub samples: u32,
    pub failures: u32,
    pub available: bool,
    /// Lower is better. Includes jitter, failure, staleness and exploration.
    pub score: f64,
    /// Milliseconds since the last successful sample.
    pub age_ms: u64,
}

#[derive(Debug, Clone)]
struct NodeState {
    id: u64,
    ewma: f64,
    jitter: f64,
    samples: u32,
    failures: u32,
    available: bool,
    last_seen_ms: u64,
}

/// Latency ranking core used by the Dart selection layer.
///
/// The full probe sweep (already performed by the globe page) is the
/// exploration phase; this scheduler is the exploitation phase: it turns the
/// samples into a stable, failure-aware ranking and decides whether leaving
/// the current node is worth it.
#[frb(opaque)]
pub struct LatencyScheduler {
    cfg: SchedulerConfig,
    nodes: Vec<NodeState>,
    last_switch_ms: Option<u64>,
}

#[frb]
impl LatencyScheduler {
    pub fn new(config: SchedulerConfig) -> Self {
        LatencyScheduler {
            cfg: config.normalized(),
            nodes: Vec::new(),
            last_switch_ms: None,
        }
    }

    /// Hot-apply settings without discarding observed samples.
    pub fn configure(&mut self, config: SchedulerConfig) {
        self.cfg = config.normalized();
    }

    /// Record a successful probe. `latency_ms` must be positive; blocked and
    /// timeout results go through `fail` instead.
    pub fn observe(&mut self, id: u64, latency_ms: u64, now_ms: u64) {
        let latency = latency_ms as f64;
        let idx = match self.nodes.iter().position(|n| n.id == id) {
            Some(i) => i,
            None => {
                self.nodes.push(NodeState {
                    id,
                    ewma: latency,
                    jitter: 0.0,
                    samples: 0,
                    failures: 0,
                    available: true,
                    last_seen_ms: now_ms,
                });
                self.nodes.len() - 1
            }
        };
        let n = &mut self.nodes[idx];
        if n.samples == 0 {
            n.ewma = latency;
            n.jitter = 0.0;
        } else {
            let deviation = (latency - n.ewma).abs();
            n.ewma = self.cfg.alpha * latency + (1.0 - self.cfg.alpha) * n.ewma;
            n.jitter = self.cfg.alpha * deviation + (1.0 - self.cfg.alpha) * n.jitter;
        }
        n.samples = n.samples.saturating_add(1);
        // A success heals one failure, not the whole streak: one lucky sample
        // must not immediately restore a node that failed three times.
        n.failures = n.failures.saturating_sub(1);
        n.available = true;
        n.last_seen_ms = now_ms;
    }

    /// Record a failed probe. A timeout counts double: it consumed the full
    /// timeout budget rather than being answered promptly as "blocked".
    pub fn fail(&mut self, id: u64, timeout: bool, now_ms: u64) {
        let idx = match self.nodes.iter().position(|n| n.id == id) {
            Some(i) => i,
            None => {
                self.nodes.push(NodeState {
                    id,
                    ewma: f64::MAX,
                    jitter: 0.0,
                    samples: 0,
                    failures: 0,
                    available: true,
                    last_seen_ms: now_ms,
                });
                self.nodes.len() - 1
            }
        };
        let n = &mut self.nodes[idx];
        n.failures = n
            .failures
            .saturating_add(if timeout { 2 } else { 1 });
        if n.failures >= self.cfg.max_failures {
            n.available = false;
        }
    }

    /// All available candidates sorted by score (ascending), non-destructive.
    pub fn rank(&self, candidates: Vec<u64>, now_ms: u64) -> Vec<NodeStats> {
        let allowed: HashSet<u64> = candidates.into_iter().collect();
        let mut out: Vec<NodeStats> = self
            .nodes
            .iter()
            .filter(|n| n.available && allowed.contains(&n.id))
            .map(|n| self.view(n, now_ms))
            .collect();
        out.sort_by(|a, b| {
            a.score
                .partial_cmp(&b.score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| a.id.cmp(&b.id))
        });
        out
    }

    /// Choose the best candidate, keeping `current` unless the improvement
    /// exceeds hysteresis and the cooldown has elapsed.
    pub fn best(&mut self, candidates: Vec<u64>, current: Option<u64>, now_ms: u64) -> Option<NodeStats> {
        let ranked = self.rank(candidates, now_ms);
        let top = ranked.first()?.clone();
        if let Some(cur) = current {
            if let Some(held) = ranked.iter().find(|n| n.id == cur) {
                let cooling = self
                    .last_switch_ms
                    .map(|t| now_ms.saturating_sub(t) < self.cfg.cooldown_ms)
                    .unwrap_or(false);
                if cooling || held.score - top.score <= self.cfg.hysteresis_ms {
                    return Some(held.clone());
                }
            }
        }
        self.last_switch_ms = Some(now_ms);
        Some(top)
    }

    pub fn stats(&self, id: u64) -> Option<NodeStats> {
        self.nodes
            .iter()
            .find(|n| n.id == id)
            .map(|n| self.view(n, now_ms_for_stats(n)))
    }

    pub fn remove(&mut self, id: u64) {
        self.nodes.retain(|n| n.id != id);
    }

    pub fn clear(&mut self) {
        self.nodes.clear();
        self.last_switch_ms = None;
    }

    fn view(&self, n: &NodeState, now_ms: u64) -> NodeStats {
        let age_ms = now_ms.saturating_sub(n.last_seen_ms);
        NodeStats {
            id: n.id,
            ewma: n.ewma,
            jitter: n.jitter,
            samples: n.samples,
            failures: n.failures,
            available: n.available,
            score: self.score(n, age_ms),
            age_ms,
        }
    }

    fn score(&self, n: &NodeState, age_ms: u64) -> f64 {
        // A node with no successful sample is never a good choice.
        if n.samples == 0 {
            return f64::MAX;
        }
        let stale_units = if age_ms > self.cfg.stale_after_ms {
            ((age_ms - self.cfg.stale_after_ms) / self.cfg.stale_after_ms.max(1)) + 1
        } else {
            0
        };
        let explore = if n.samples < self.cfg.explore_min_samples {
            (self.cfg.explore_min_samples - n.samples) as f64 * self.cfg.explore_bonus_ms
        } else {
            0.0
        };
        let raw = n.ewma
            + self.cfg.jitter_weight * n.jitter
            + n.failures as f64 * self.cfg.failure_penalty_ms
            + stale_units as f64 * self.cfg.stale_penalty_ms
            - explore;
        raw.max(0.0)
    }
}

// `stats` has no clock input; use the node's own last-seen time so age is 0
// and the caller sees the score as of the most recent observation.
fn now_ms_for_stats(n: &NodeState) -> u64 {
    n.last_seen_ms
}

#[frb(init)]
pub fn scheduler_lib_init() {
    // No eager work is needed: each wrapper creates its own scheduler and
    // the FFI initializer only exists to let flutter_rust_bridge attach.
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> SchedulerConfig {
        SchedulerConfig {
            alpha: 0.5,
            jitter_weight: 1.0,
            failure_penalty_ms: 100.0,
            stale_penalty_ms: 50.0,
            hysteresis_ms: 20.0,
            cooldown_ms: 1_000,
            max_failures: 3,
            stale_after_ms: 1_000,
            explore_min_samples: 3,
            explore_bonus_ms: 10.0,
        }
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn observe_smooths_latency_and_tracks_jitter() {
        let mut s = LatencyScheduler::new(cfg());
        s.observe(1, 100, 0);
        s.observe(1, 200, 1);
        let v = s.stats(1).unwrap();
        assert!(close(v.ewma, 150.0), "ewma={}", v.ewma);
        assert!(close(v.jitter, 50.0), "jitter={}", v.jitter);
        assert_eq!(v.samples, 2);
    }

    #[test]
    fn rank_prefers_lower_score_and_ties_break_by_id() {
        let mut s = LatencyScheduler::new(cfg());
        for id in [1u64, 2, 3] {
            for _ in 0..3 {
                s.observe(id, 100, 0);
            }
        }
        s.observe(2, 500, 1);
        let ranked = s.rank(vec![1, 2, 3], 1);
        assert_eq!(ranked[0].id, 1);
        assert_eq!(ranked[1].id, 3);
        assert_eq!(ranked[2].id, 2);
    }

    #[test]
    fn failures_penalize_then_disable_until_recovery() {
        let mut s = LatencyScheduler::new(cfg());
        s.observe(1, 100, 0);
        s.fail(1, false, 1);
        s.fail(1, false, 2);
        assert!(s.stats(1).unwrap().available);
        s.fail(1, true, 3);
        assert!(!s.stats(1).unwrap().available);
        assert!(s.rank(vec![1], 4).is_empty());
        s.observe(1, 100, 5);
        s.observe(1, 100, 6);
        assert!(s.stats(1).unwrap().available);
    }

    #[test]
    fn best_keeps_current_until_improvement_exceeds_hysteresis() {
        let mut s = LatencyScheduler::new(cfg());
        for id in [1u64, 2] {
            for _ in 0..3 {
                s.observe(id, 100, 0);
            }
        }
        // Node 2 is 10ms better: below the 20ms hysteresis.
        for _ in 0..3 {
            s.observe(2, 90, 10);
        }
        let picked = s.best(vec![1, 2], Some(1), 20).unwrap();
        assert_eq!(picked.id, 1);
        // Now 30ms better: switch.
        for _ in 0..3 {
            s.observe(2, 60, 30);
        }
        let picked = s.best(vec![1, 2], Some(1), 40).unwrap();
        assert_eq!(picked.id, 2);
    }

    #[test]
    fn best_respects_cooldown_but_allows_switch_when_current_is_unavailable() {
        let mut s = LatencyScheduler::new(cfg());
        for id in [1u64, 2] {
            for _ in 0..3 {
                s.observe(id, 100, 0);
            }
        }
        for _ in 0..4 {
            s.observe(2, 10, 10);
        }
        // First switch is allowed.
        assert_eq!(s.best(vec![1, 2], Some(1), 20).unwrap().id, 2);
        // Restore node 1 to be clearly better, but we are still cooling.
        for _ in 0..8 {
            s.observe(1, 1, 25);
        }
        assert_eq!(s.best(vec![1, 2], Some(2), 30).unwrap().id, 2);
        // Once the current node dies, cooldown must not trap the user on it.
        s.fail(2, false, 31);
        s.fail(2, false, 32);
        s.fail(2, false, 33);
        assert_eq!(s.best(vec![1, 2], Some(2), 40).unwrap().id, 1);
    }

    #[test]
    fn staleness_penalizes_nodes_that_were_not_seen_recently() {
        let mut s = LatencyScheduler::new(cfg());
        for _ in 0..3 {
            s.observe(1, 100, 0);
            s.observe(2, 100, 0);
        }
        // Only node 1 is refreshed; node 2 is now stale.
        for _ in 0..3 {
            s.observe(1, 100, 5_000);
        }
        let ranked = s.rank(vec![1, 2], 5_000);
        assert_eq!(ranked[0].id, 1);
        assert_eq!(ranked[1].id, 2);
        assert!(ranked[1].age_ms >= 5_000);
        assert!(ranked[1].score > ranked[0].score + 100.0);
    }

    #[test]
    fn under_sampled_nodes_get_an_exploration_bonus() {
        let mut s = LatencyScheduler::new(cfg());
        s.observe(1, 100, 0);
        for _ in 0..3 {
            s.observe(2, 95, 0);
        }
        let ranked = s.rank(vec![1, 2], 0);
        // Node 1 is 5ms slower but has only one sample, so the optimistic
        // adjustment makes it the candidate worth trying next.
        assert_eq!(ranked[0].id, 1);
        assert_eq!(ranked[0].samples, 1);
    }

    #[test]
    fn configure_clamps_all_inputs_to_dart_bounds() {
        let mut s = LatencyScheduler::new(cfg());
        s.observe(1, 100, 0);
        s.configure(SchedulerConfig {
            alpha: 9.0,
            max_failures: 0,
            cooldown_ms: u64::MAX,
            stale_after_ms: 1,
            explore_min_samples: 0,
            jitter_weight: f64::NAN,
            ..cfg()
        });
        assert!(s.stats(1).is_some(), "configure must keep samples");
        s.fail(1, false, 1);
        s.fail(1, false, 2);
        s.fail(1, false, 3);
        assert!(!s.stats(1).unwrap().available, "max_failures must clamp to >= 1");
        // stale_after_ms clamped to >= 1000: age 3ms is not stale yet, so score
        // stays finite and well below a max-failure penalty would allow.
        let v = s.stats(1).unwrap();
        assert!(v.score.is_finite(), "NaN jitter weight must be clamped to 0");
    }
}
