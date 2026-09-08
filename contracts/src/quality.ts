/**
 * Quality vector, hard gates, failure localization, continuity state.
 * Normative: SPEC/50-quality-vector.md, SPEC/60-continuity.md.
 */

import { s, emit, type Infer, type Node } from "./schema.js";

/**
 * Every dimension is nullable. A null is "not measured"; zero is "measured as terrible". Conflating
 * them is how an unmeasured system passes a gate it was never evaluated against.
 */
const dim = (note: string): Node<number | null> => s.nullable(s.score(note));

export const QUALITY_DIMENSIONS = [
  "prompt_adherence_mu", "character_identity_mu", "temporal_identity_mu", "anatomy_mu",
  "motion_coherence_mu", "motion_complexity_mu", "physical_plausibility_mu",
  "interaction_correctness_mu", "camera_accuracy_mu", "spatial_consistency_mu",
  "depth_consistency_mu", "occlusion_consistency_mu", "lighting_consistency_mu",
  "material_consistency_mu", "environment_consistency_mu", "style_consistency_mu",
  "reference_adherence_mu", "narrative_progression_mu", "audio_alignment_mu",
  "continuity_start_mu", "continuity_end_mu", "artifact_severity_mu",
] as const;

export const MEASUREMENT_BASIS = s.enum([
  "MEASURED", "DECLARED", "INFERRED", "PROXY", "UNAVAILABLE",
] as const);

export const QUALITY_VECTOR = s.obj({
  prompt_adherence_mu: dim("Does the output do what the prompt specified"),
  character_identity_mu: dim("Identity preserved against the identity anchor"),
  temporal_identity_mu: dim("Identity preserved across frames within the segment"),
  anatomy_mu: dim("Anatomical coherence"),
  motion_coherence_mu: dim("Motion is continuous and explicable"),
  motion_complexity_mu: dim("Motion is as complex as specified, not simplified away"),
  physical_plausibility_mu: dim("Behaviour consistent with physics expectations"),
  interaction_correctness_mu: dim("Interaction graph realised correctly"),
  camera_accuracy_mu: dim("Camera did what the camera motion specified"),
  spatial_consistency_mu: dim("Spatial layout preserved"),
  depth_consistency_mu: dim("Depth layer ordering preserved"),
  occlusion_consistency_mu: dim("Occlusion behaves consistently"),
  lighting_consistency_mu: dim("Lighting stable or transitioning as specified"),
  material_consistency_mu: dim("Material behaviour consistent"),
  environment_consistency_mu: dim("Environment does not drift"),
  style_consistency_mu: dim("Visual style held"),
  reference_adherence_mu: dim("References honoured within their bound roles"),
  narrative_progression_mu: dim("Narrative advanced as specified"),
  audio_alignment_mu: dim("Audio aligned with visual events"),
  continuity_start_mu: dim("First frame compatible with the previous terminal state"),
  continuity_end_mu: dim("Final frame leaves an extendable state"),
  artifact_severity_mu: dim("INVERTED: higher is worse. Kept unnegated to match what is measured."),

  measurement_basis: s.obj({
    per_dimension: s.arr(s.obj({ dimension: s.str(), basis: MEASUREMENT_BASIS, detail: s.str() })),
  }),
  forbidden_event_count: s.int("count", { min: 0 }),
});
export type QualityVector = Infer<typeof QUALITY_VECTOR>;

export const HARD_GATE = s.obj({
  dimension: s.str(),
  comparator: s.enum(["gte", "lte", "eq"] as const),
  threshold_mu: s.int("mu"),
  rationale: s.str(),
});

export const GATE_RESULT = s.obj({
  accepted: s.bool(),
  failures: s.arr(s.obj({
    dimension: s.str(),
    comparator: s.str(),
    threshold_mu: s.int("mu"),
    actual_mu: s.nullable(s.int("mu")),
    reason: s.enum(["BELOW_THRESHOLD", "ABOVE_THRESHOLD", "NOT_EQUAL", "UNMEASURED"] as const),
    margin_mu: s.nullable(s.int("mu")),
  }), "A rejection without a locus forces blind regeneration, so every failure names its gate."),
});
export type GateResult = Infer<typeof GATE_RESULT>;

export const FAILURE_TYPE = s.enum([
  "IDENTITY_DRIFT", "ANATOMY_FAILURE", "MOTION_FAILURE", "PHYSICS_FAILURE", "CAMERA_FAILURE",
  "DEPTH_FAILURE", "OCCLUSION_FAILURE", "LIGHTING_FAILURE", "REFERENCE_FAILURE", "STYLE_FAILURE",
  "TEMPORAL_DISCONTINUITY", "OBJECT_PERSISTENCE_FAILURE", "ENVIRONMENT_DRIFT", "AUDIO_FAILURE",
  "NARRATIVE_FAILURE", "PROVIDER_LIMITATION", "UNKNOWN",
] as const);

export const FAILURE_LOCALIZATION = s.obj({
  failure_type: FAILURE_TYPE,
  failing_dimensions: s.arr(s.str()),
  time_window_ms: s.obj({ start: s.int("ms"), end: s.int("ms") }),
  spatial_region: s.nullable(s.obj({
    x_px: s.int("px"), y_px: s.int("px"), w_px: s.int("px"), h_px: s.int("px"),
  })),
  evidence: s.arr(s.str()),
  confidence_ppm: s.ppm(),
  suggested_repair: s.str({
    note: "Targets only the failing dimensions. A prompt that worked is not rewritten wholesale.",
  }),
});
export type FailureLocalization = Infer<typeof FAILURE_LOCALIZATION>;

// --- Continuity --------------------------------------------------------------

const vec3mm = s.obj({ x: s.int("mm"), y: s.int("mm"), z: s.int("mm") });
const vec3mdeg = s.obj({ pan: s.int("mdeg"), tilt: s.int("mdeg"), roll: s.int("mdeg") });

export const CONTINUITY_STATE = s.obj({
  segment_id: s.str(),
  source_record_id: s.digestRef("The ledger record that established this as verified history"),

  subject_positions: s.arr(s.obj({ subject_id: s.str(), position_mm: vec3mm })),
  subject_orientations: s.arr(s.obj({ subject_id: s.str(), orientation_mdeg: vec3mdeg })),
  body_configuration: s.arr(s.obj({ subject_id: s.str(), configuration: s.str() })),
  velocities: s.arr(s.obj({ subject_id: s.str(), velocity_mm_per_s: vec3mm })),
  angular_velocities: s.arr(s.obj({ subject_id: s.str(), angular_mdeg_per_s: vec3mdeg })),

  active_actions: s.arr(s.obj({ subject_id: s.str(), action: s.str(), phase: s.str() })),
  contact_states: s.arr(s.obj({ subject_id: s.str(), contact_with: s.str(), kind: s.str() })),
  carried_objects: s.arr(s.obj({ subject_id: s.str(), object_id: s.str() })),
  clothing_state: s.str(),
  hair_state: s.str(),
  damage_or_deformation_state: s.str(),

  environment_state: s.str(),
  object_positions: s.arr(s.obj({ object_id: s.str(), position_mm: vec3mm })),

  camera_position_mm: vec3mm,
  camera_orientation_mdeg: vec3mdeg,
  camera_velocity_mm_per_s: vec3mm,
  focal_behavior: s.str(),

  lighting_state: s.str(),
  particle_state: s.str(),
  fluid_state: s.str(),
  audio_phase: s.nullable(s.str()),
  narrative_state: s.str(),

  unresolved_motion: s.arr(s.str(), "Must be non-empty for an extendable ending"),
  unresolved_causal_events: s.arr(s.str()),
  final_frame_visual_signature: s.str({
    pattern: "^[0-9a-f]{64}$",
    note: "From core/c/libb1sig. Genuinely measured, unlike most fields here.",
  }),

  measurement_basis: s.arr(s.obj({ field: s.str(), basis: MEASUREMENT_BASIS })),
});
export type ContinuityState = Infer<typeof CONTINUITY_STATE>;

export const CONTINUATION_SOURCE = s.enum([
  "P1_VERIFIED_PREVIOUS_CLIP",
  "P2_TERMINAL_CONTINUITY_STATE",
  "P3_USER_CONTINUATION_INSTRUCTION",
  "P4_NEW_REFERENCE_MEDIA",
  "P5_STYLE_GUIDANCE",
  "P6_SYSTEM_INFERRED",
] as const);

export const CONTINUATION_CONFLICT = s.obj({
  higher: CONTINUATION_SOURCE,
  lower: CONTINUATION_SOURCE,
  contested_field: s.str(),
  resolution: s.str({ note: "Always in favour of the higher priority; the suppression is recorded" }),
  user_override: s.bool("True only where the user explicitly authorized the contradiction"),
});

export const COMPATIBILITY_RESULT = s.obj({
  compatible: s.bool(),
  violations: s.arr(s.obj({
    predicate: s.enum([
      "POSITIONAL_DRIFT", "VELOCITY_CONTINUITY", "CONTACT_STATE", "CARRIED_OBJECTS",
      "CAMERA_CONTINUITY", "LIGHTING_CONTINUITY", "VISUAL_SIGNATURE_DISTANCE",
    ] as const),
    detail: s.str(),
    measured: s.nullable(s.int("unitless")),
    tolerance: s.int("unitless"),
  }), "Names the violated predicate. 'Continuity failed' alone is not actionable."),
});

export const QUALITY_SCHEMA = emit("quality-vector", "QualityVector", QUALITY_VECTOR);
export const CONTINUITY_SCHEMA = emit("continuity-state", "ContinuityState", CONTINUITY_STATE);
export const FAILURE_SCHEMA = emit("failure-localization", "FailureLocalization", FAILURE_LOCALIZATION);
