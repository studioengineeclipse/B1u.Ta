/**
 * Ledger records, authority envelopes, provider capability, and evidence.
 * Normative: SPEC/30-causal-ledger.md, SPEC/40-authority-gate.md, SPEC/70-provider-routes.md.
 */

import { s, emit, type Infer } from "./schema.js";
import { ORIGIN } from "./ir.js";

export const EFFECT_CLASS = s.enum([
  "REVERSIBLE", "COMPENSATABLE", "IRREVERSIBLE", "UNKNOWN",
] as const);

export const PRESENT_VALIDITY = s.enum([
  "VERIFIED", "WORKING_ASSUMPTION", "UNKNOWN", "IN_DOUBT",
] as const);

export const OUTCOME = s.enum([
  "VERIFIED", "PARTIAL", "FAILED", "IN_DOUBT", "NOT_EXECUTED",
] as const);

export const GATE_STATE = s.enum([
  "OPEN", "CLOSED_UNAUTHORIZED", "CLOSED_STALE", "CLOSED_EXPIRED",
  "CLOSED_SCOPE_VIOLATION", "CLOSED_UNKNOWN_RECOVERY",
] as const);

export const ACTION = s.obj({
  kind: s.str({ note: "e.g. generate_segment, write_file, push_branch, provider_call" }),
  summary: s.str(),
  target: s.str(),
  persistent: s.bool("Whether this action produces a lasting state transition"),
});

export const AUTHORITY_ENVELOPE = s.obj({
  envelope_id: s.str({ pattern: "^[a-z0-9_-]{1,64}$" }),
  proposed_action: ACTION,
  target: s.str(),
  scope: s.arr(s.str(), "Bounds of the authorization. What is not listed is not authorized."),
  expected_effect: s.str(),
  relevant_state_digest: s.digestRef("Digest of the state the plan assumed"),
  plan_digest: s.digestRef("Digest of the plan at authorization time"),
  causal_objective: s.str(),
  effect_class: EFFECT_CLASS,
  authorized_at_ms: s.int("ms"),
  authorized_by: s.str(),
  max_age_ms: s.int("ms", { note: "After this, the authorization is EXPIRED" }),
});
export type AuthorityEnvelope = Infer<typeof AUTHORITY_ENVELOPE>;

export const EFFECT_TIME_VALIDATION = s.obj({
  checked_at_ms: s.int("ms"),
  gate_state: GATE_STATE,
  recomputed_envelope_digest: s.digestRef(),
  matched: s.bool(),
  detail: s.opt(s.str()),
});

export const RECEIPT = s.obj({
  executor_claim: s.str({ note: "What the executor said happened. Evidence, never proof." }),
  status_code: s.opt(s.str()),
  received_at_ms: s.int("ms"),
});

export const OBSERVED_EFFECT = s.obj({
  observation: s.str({ note: "What was independently observed, not what was claimed" }),
  observer: s.str(),
  observed_at_ms: s.int("ms"),
  media_digest: s.opt(s.digestRef()),
});

export const POSTCONDITION = s.obj({
  statement: s.str(),
  satisfied: s.bool(),
  method: s.str({ note: "How satisfaction was determined" }),
  unmet: s.arr(s.str()),
});

export const EVIDENCE = s.obj({
  kind: s.str(),
  detail: s.str(),
  digest: s.opt(s.digestRef()),
});

export const RECOVERY_STATE = s.obj({
  available: s.bool(),
  method: s.opt(s.str()),
  known_data_loss: s.arr(s.str()),
  unknown_data_loss: s.bool("True when the extent of loss could not be established"),
});

/**
 * Receipt, observed effect and objective postcondition are three separate nullable fields.
 * That separation is the whole point: a populated receipt beside a null observed_effect is a
 * visible IN_DOUBT rather than something that reads like success.
 */
export const LEDGER_RECORD = s.obj({
  seq: s.int("count", { min: 0 }),
  prev_link: s.digestRef(),
  record_id: s.digestRef(),

  goal: s.str(),
  derived_need: s.str(),
  origin: ORIGIN,
  causal_parents: s.arr(s.digestRef()),

  authority: s.str(),
  authorization_ref: s.nullable(s.str()),
  envelope_digest: s.nullable(s.digestRef()),
  effect_time_validation: s.nullable(EFFECT_TIME_VALIDATION),

  executor: s.str({ note: "Program identity: which logical component was to act" }),
  execution_identity: s.str({ note: "Which concrete runtime/process/provider instance acted" }),
  attempt_identity: s.str({ note: "Which attempt. A retry is a new attempt, never the same one." }),

  action: ACTION,
  receipt: s.nullable(RECEIPT),
  observed_effect: s.nullable(OBSERVED_EFFECT),
  objective_postcondition: s.nullable(POSTCONDITION),

  persistent_id: s.nullable(s.str()),
  user_visible: s.bool(),
  reason_persisted: s.nullable(s.str()),
  effect_class: EFFECT_CLASS,

  evidence: s.arr(EVIDENCE),
  proof: s.nullable(s.obj({ claim: s.str(), basis: s.str() })),
  present_validity: PRESENT_VALIDITY,
  recovery_state: s.nullable(RECOVERY_STATE),

  observed_at_ms: s.int("ms"),
});
export type LedgerRecord = Infer<typeof LEDGER_RECORD>;

// --- Provider capability -----------------------------------------------------

export const ROUTE = s.enum([
  "A_OFFICIAL_SEEDANCE", "B_NETA_ROUTER", "C_NETA_NATIVE", "D_OTHER_AUTHORIZED", "E_PLANNING_ONLY",
] as const);

export const CONTRACT_STATUS = s.enum(["VERIFIED", "CONTRACT_UNVERIFIED", "UNKNOWN"] as const);

/**
 * Every capability field is nullable and starts null. A null means "not established" — it is never
 * filled from documentation the system has not fetched, nor from what a similar provider does.
 */
export const PROVIDER_CAPABILITY = s.obj({
  provider_id: s.str(),
  route: ROUTE,
  auth_method: s.nullable(s.str()),
  base_url: s.nullable(s.str()),
  available_models: s.nullable(s.arr(s.str())),
  input_modalities: s.nullable(s.arr(s.enum(["TEXT", "IMAGE", "VIDEO", "AUDIO"] as const))),
  output_modalities: s.nullable(s.arr(s.enum(["VIDEO", "IMAGE", "AUDIO"] as const))),
  duration_limits_ms: s.nullable(s.obj({ min: s.int("ms"), max: s.int("ms") })),
  resolution_limits: s.nullable(s.obj({ max_width_px: s.int("px"), max_height_px: s.int("px") })),
  reference_limits: s.nullable(s.obj({ max_references: s.int("count") })),
  extension_support: s.nullable(s.bool()),
  audio_support: s.nullable(s.bool()),
  currently_verified_at_ms: s.nullable(s.int("ms")),
  evidence_source: s.str({ note: "How each populated field was established" }),
  contract_status: CONTRACT_STATUS,
  credential_present: s.bool("Credential existence. Never conflated with entitlement."),
  entitlement_observed: s.nullable(s.bool("Null until a capability query actually succeeded")),
});
export type ProviderCapability = Infer<typeof PROVIDER_CAPABILITY>;

// --- Evidence ----------------------------------------------------------------

export const TRANSFERABILITY = s.enum([
  "PROVIDER_SPECIFIC", "HYPOTHESIS_ONLY", "CROSS_PROVIDER_OBSERVED", "UNKNOWN",
] as const);

export const EVIDENCE_RECORD = s.obj({
  record_id: s.digestRef(),
  source: s.str({ note: "e.g. sora_observation, provider_experiment" }),
  observation: s.str(),
  confidence_ppm: s.ppm(),
  conditions: s.str(),
  applicable_provider: s.nullable(s.str()),
  transferability: TRANSFERABILITY,
  failure_cases: s.arr(s.str()),
  recorded_at_ms: s.int("ms"),
  origin: ORIGIN,
});
export type EvidenceRecord = Infer<typeof EVIDENCE_RECORD>;

// --- Generation package (the Route E deliverable) -----------------------------

export const GENERATION_PACKAGE = s.obj({
  package_version: s.lit("b1-generation-package/1"),
  ir_digest: s.digestRef(),
  route: ROUTE,
  provider_id: s.nullable(s.str()),
  model: s.nullable(s.str()),
  compiled_prompt: s.str(),
  negative_prompt: s.nullable(s.str()),
  reference_manifest: s.arr(s.obj({
    reference_id: s.str(),
    role: s.str(),
    media_digest: s.digestRef(),
    provider_slot: s.nullable(s.str({ note: "Null while the provider contract is unverified" })),
  })),
  provider_request: s.nullable(s.obj({
    contract_status: CONTRACT_STATUS,
    body_canonical: s.str({ note: "Canonical JSON of the request body as compiled" }),
  })),
  continuation_state_digest: s.nullable(s.digestRef()),
  gate_policy_digest: s.digestRef(),
  execution_status: s.enum(["NOT_EXECUTED", "EXECUTED"] as const),
  outcome: OUTCOME,
  notes: s.arr(s.str()),
});
export type GenerationPackage = Infer<typeof GENERATION_PACKAGE>;

export const LEDGER_SCHEMA = emit("ledger-record", "LedgerRecord", LEDGER_RECORD);
export const ENVELOPE_SCHEMA = emit("authority-envelope", "AuthorityEnvelope", AUTHORITY_ENVELOPE);
export const CAPABILITY_SCHEMA = emit("provider-capability", "ProviderCapability", PROVIDER_CAPABILITY);
export const EVIDENCE_SCHEMA = emit("evidence-record", "EvidenceRecord", EVIDENCE_RECORD);
export const PACKAGE_SCHEMA = emit("generation-package", "GenerationPackage", GENERATION_PACKAGE);
