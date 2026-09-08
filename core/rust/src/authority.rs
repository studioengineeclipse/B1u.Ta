//! The authority and persistence gate. Normative: SPEC/40-authority-gate.md.
//!
//! This is the mechanism behind `PLAN_READY ≠ EXECUTION_AUTHORIZED`. The key property is that
//! staleness is detected *mechanically* rather than by good intentions: because the envelope binds
//! digests of the state the plan assumed and of the plan itself, any drift in either changes the
//! recomputed digest and closes the gate. The system cannot proceed on a stale authorization even
//! if every component intends to behave.

use crate::canon::{digest_value, Json, B1Error};
use crate::ledger::{EffectClass, EffectTimeValidation};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateState {
    Open,
    /// No envelope at all. The gate defaults to closed; absence is never an implicit open.
    ClosedUnauthorized,
    /// Something materially relevant changed after authorization.
    ClosedStale,
    ClosedExpired,
    ClosedScopeViolation,
    /// Policy requires a known recovery path for this effect class and none was established.
    ClosedUnknownRecovery,
}

impl GateState {
    pub fn as_str(self) -> &'static str {
        match self {
            GateState::Open => "OPEN",
            GateState::ClosedUnauthorized => "CLOSED_UNAUTHORIZED",
            GateState::ClosedStale => "CLOSED_STALE",
            GateState::ClosedExpired => "CLOSED_EXPIRED",
            GateState::ClosedScopeViolation => "CLOSED_SCOPE_VIOLATION",
            GateState::ClosedUnknownRecovery => "CLOSED_UNKNOWN_RECOVERY",
        }
    }
    pub fn is_open(self) -> bool {
        matches!(self, GateState::Open)
    }
}

#[derive(Debug, Clone)]
pub struct Envelope {
    pub envelope_id: String,
    pub action_kind: String,
    pub action_summary: String,
    pub target: String,
    /// Bounds of the authorization. What is not listed here is not authorized.
    pub scope: Vec<String>,
    pub expected_effect: String,
    /// Digest of the state the plan assumed when authorization was given.
    pub relevant_state_digest: String,
    /// Digest of the plan at authorization time.
    pub plan_digest: String,
    pub causal_objective: String,
    pub effect_class: EffectClass,
    pub authorized_at_ms: i64,
    pub authorized_by: String,
    pub max_age_ms: i64,
}

impl Envelope {
    /// The bound content. `envelope_id` and `authorized_at_ms` are excluded: they identify and
    /// timestamp the authorization rather than describe what was authorized, so re-issuing the same
    /// authorization does not look like a different one.
    fn bound_content(&self, state_digest: &str, plan_digest: &str) -> Json {
        Json::obj(vec![
            ("action_kind", Json::s(self.action_kind.clone())),
            ("action_summary", Json::s(self.action_summary.clone())),
            ("target", Json::s(self.target.clone())),
            (
                "scope",
                Json::Arr(self.scope.iter().map(Json::s).collect()),
            ),
            ("expected_effect", Json::s(self.expected_effect.clone())),
            ("relevant_state_digest", Json::s(state_digest)),
            ("plan_digest", Json::s(plan_digest)),
            ("causal_objective", Json::s(self.causal_objective.clone())),
            ("effect_class", Json::s(self.effect_class.as_str())),
            ("authorized_by", Json::s(self.authorized_by.clone())),
        ])
    }

    /// The digest as bound at authorization time.
    pub fn digest(&self) -> Result<String, B1Error> {
        digest_value(&self.bound_content(&self.relevant_state_digest, &self.plan_digest))
    }

    /// The digest recomputed against the state and plan as they are *now*.
    pub fn recompute(&self, current_state_digest: &str, current_plan_digest: &str) -> Result<String, B1Error> {
        digest_value(&self.bound_content(current_state_digest, current_plan_digest))
    }
}

/// What the caller is about to do, checked against what was authorized.
#[derive(Debug, Clone)]
pub struct ProposedEffect {
    pub action_kind: String,
    pub target: String,
    /// The scope entry this effect falls under. Must appear in the envelope's scope.
    pub scope_entry: String,
    pub current_state_digest: String,
    pub current_plan_digest: String,
    pub now_ms: i64,
}

#[derive(Debug, Clone)]
pub struct GateDecision {
    pub state: GateState,
    pub detail: String,
    pub recomputed_digest: String,
}

impl GateDecision {
    pub fn to_validation(&self, now_ms: i64) -> EffectTimeValidation {
        EffectTimeValidation {
            checked_at_ms: now_ms,
            gate_state: self.state.as_str().to_string(),
            recomputed_envelope_digest: self.recomputed_digest.clone(),
            matched: self.state.is_open(),
            detail: Some(self.detail.clone()),
        }
    }
}

/// Policy knobs. `require_known_recovery` exists so a deployment can refuse to authorize effects
/// whose recovery characteristics could not be established, rather than discovering the limit
/// afterwards.
#[derive(Debug, Clone, Copy)]
pub struct Policy {
    pub require_known_recovery: bool,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            require_known_recovery: true,
        }
    }
}

/// Checks the gate **at effect time**, immediately before the persistent transition.
///
/// Planning-time approval is not permanent authorization and admission-time approval is not
/// effect-time authorization, so this is called again at the moment of the effect and its result is
/// recorded in the ledger — the record then shows not merely that authorization existed, but that
/// it was still valid when the effect occurred.
pub fn check_at_effect_time(
    envelope: Option<&Envelope>,
    proposed: &ProposedEffect,
    policy: Policy,
) -> GateDecision {
    let Some(env) = envelope else {
        return GateDecision {
            state: GateState::ClosedUnauthorized,
            detail: "no authority envelope is bound to this effect".into(),
            recomputed_digest: String::new(),
        };
    };

    let recomputed = match env.recompute(&proposed.current_state_digest, &proposed.current_plan_digest)
    {
        Ok(d) => d,
        Err(e) => {
            return GateDecision {
                state: GateState::ClosedStale,
                detail: format!("envelope could not be canonicalized: {}", e.token()),
                recomputed_digest: String::new(),
            }
        }
    };

    // Scope is checked before staleness so a scope violation is reported as such rather than being
    // masked by an unrelated drift in state.
    if !env.scope.iter().any(|s| s == &proposed.scope_entry) {
        return GateDecision {
            state: GateState::ClosedScopeViolation,
            detail: format!(
                "effect scope {:?} is not among the authorized scope {:?}",
                proposed.scope_entry, env.scope
            ),
            recomputed_digest: recomputed,
        };
    }

    if env.action_kind != proposed.action_kind || env.target != proposed.target {
        return GateDecision {
            state: GateState::ClosedScopeViolation,
            detail: format!(
                "authorized {}→{}, proposed {}→{}",
                env.action_kind, env.target, proposed.action_kind, proposed.target
            ),
            recomputed_digest: recomputed,
        };
    }

    let bound = match env.digest() {
        Ok(d) => d,
        Err(e) => {
            return GateDecision {
                state: GateState::ClosedStale,
                detail: format!("bound envelope digest unavailable: {}", e.token()),
                recomputed_digest: recomputed,
            }
        }
    };

    if recomputed != bound {
        return GateDecision {
            state: GateState::ClosedStale,
            detail:
                "the state or plan changed after authorization; the authorization no longer describes this effect"
                    .into(),
            recomputed_digest: recomputed,
        };
    }

    if proposed.now_ms > env.authorized_at_ms.saturating_add(env.max_age_ms) {
        return GateDecision {
            state: GateState::ClosedExpired,
            detail: format!(
                "authorization expired {} ms ago",
                proposed.now_ms - env.authorized_at_ms - env.max_age_ms
            ),
            recomputed_digest: recomputed,
        };
    }

    if policy.require_known_recovery && env.effect_class == EffectClass::Unknown {
        return GateDecision {
            state: GateState::ClosedUnknownRecovery,
            detail: "recovery characteristics could not be established before authorization".into(),
            recomputed_digest: recomputed,
        };
    }

    GateDecision {
        state: GateState::Open,
        detail: "authorization is bound, in scope, current and unexpired".into(),
        recomputed_digest: recomputed,
    }
}

/// A persistent state transition observed with no authorized action explaining it (law L10).
///
/// Such state is never retroactively treated as authorized and never silently normalized. If
/// provenance is later established, a *new* record references this anomaly as a causal parent
/// rather than editing it away.
#[derive(Debug, Clone)]
pub struct Anomaly {
    pub observed: String,
    pub origin_guess: String,
    pub evidence: Vec<String>,
    pub detail: String,
}

/// Reconciles observed persistent identifiers against those the ledger accounts for.
pub fn detect_anomalies(observed_ids: &[String], accounted_ids: &[String]) -> Vec<Anomaly> {
    observed_ids
        .iter()
        .filter(|id| !accounted_ids.contains(id))
        .map(|id| Anomaly {
            observed: id.clone(),
            // P or E cannot be distinguished without more context, and guessing between them would
            // itself be a fabricated attribution. UNKNOWN is the honest classification.
            origin_guess: "UNKNOWN".into(),
            evidence: vec![format!("persistent id {id} present but unaccounted for in the ledger")],
            detail: "state exists with no authorized action explaining it; marked IN_DOUBT".into(),
        })
        .collect()
}
