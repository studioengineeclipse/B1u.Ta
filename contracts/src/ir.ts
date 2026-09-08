/**
 * B1_VIDEO_IR — the canonical creative state. Normative description: SPEC/10-b1-video-ir.md.
 *
 * This is the provider-neutral centre of the system: prompts are compiled *from* it, never the
 * other way round, and no provider-specific syntax is permitted to reach it.
 */

import { s, emit, type Infer, type Node } from "./schema.js";

export const ORIGIN = s.enum(["U", "M", "P", "E", "UNKNOWN"] as const);
export type Origin = Infer<typeof ORIGIN>;

export const REFERENCE_ROLE = s.enum([
  "CHARACTER_IDENTITY", "FACE_IDENTITY", "BODY_DESIGN", "COSTUME", "ENVIRONMENT", "OBJECT",
  "STYLE", "COLOR", "COMPOSITION", "CAMERA", "MOTION", "ANIMATION_TIMING", "POSE", "ACTION",
  "VIDEO_CONTINUITY", "AUDIO", "OTHER_EXPLICIT_ROLE",
] as const);
export type ReferenceRole = Infer<typeof REFERENCE_ROLE>;

export const SCENE_MODE = s.enum([
  "single_shot", "continuation", "extension", "variation", "repair",
] as const);

export const ENDING_PATTERN = s.enum([
  "arbitrary_freeze", "celebration", "pose", "fade_out", "hard_stop",
  "unexplained_camera_halt", "artificial_reset", "neutral_object_reset",
] as const);

const namedEntity = (extra: Record<string, Node<unknown>> = {}) =>
  s.obj({
    id: s.str({ pattern: "^[a-z0-9_-]{1,64}$" }),
    name: s.str(),
    description: s.str(),
    ...extra,
  });

export const CHARACTER = namedEntity({
  identity_anchor: s.opt(s.str({ note: "Stable trait set that must survive across segments" })),
  costume: s.opt(s.str()),
  body_design: s.opt(s.str()),
});

export const IDENTITY_CONSTRAINT = s.obj({
  character_id: s.str(),
  constraint: s.str(),
  tolerance_mu: s.score("Permitted identity drift before this constraint is violated"),
});

export const ELEMENT = namedEntity({
  depth_layer: s.opt(s.int("count", { min: 0 })),
});

export const REFERENCE_BINDING = s.obj({
  reference_id: s.str({ pattern: "^[a-z0-9_-]{1,64}$" }),
  // Nullable: a scene can be authored before its reference media exists, and a binding with no
  // bytes yet is a normal intermediate state. What is *not* legitimate is generating from one —
  // an unbound reference cannot be sent to a provider — so the constraint belongs at the
  // execution boundary, not at authoring.
  media_digest: s.nullable(s.digestRef("Digest of the referenced media bytes; null until bound")),
  role: REFERENCE_ROLE,
  role_detail: s.opt(s.str({ note: "Required when role is OTHER_EXPLICIT_ROLE" })),
  weight_ppm: s.ppm(),
  applies_to: s.arr(
    s.str(),
    "IR paths this reference may influence. The enforcement point for the no-silent-dominance rule.",
  ),
  rationale: s.str({ note: "Which identified requirement this reference serves. Never optional." }),
  origin: ORIGIN,
});

export const CAMERA_STATE = s.obj({
  position_mm: s.obj({ x: s.int("mm"), y: s.int("mm"), z: s.int("mm") }),
  orientation_mdeg: s.obj({ pan: s.int("mdeg"), tilt: s.int("mdeg"), roll: s.int("mdeg") }),
  focal_length_mm: s.int("mm"),
  framing: s.str(),
});

export const CAMERA_MOTION = s.obj({
  kind: s.enum(["static", "pan", "tilt", "dolly", "track", "crane", "handheld", "zoom", "orbit"] as const),
  start_ms: s.int("ms"),
  end_ms: s.int("ms"),
  magnitude_mm: s.opt(s.int("mm")),
  magnitude_mdeg: s.opt(s.int("mdeg")),
  subject_framing_note: s.opt(s.str({ note: "Observable framing behaviour, not a quality adjective" })),
});

export const SUBJECT_MOTION = s.obj({
  subject_id: s.str(),
  action: s.str(),
  start_ms: s.int("ms"),
  end_ms: s.int("ms"),
  phase_at_start: s.opt(s.str({ note: "e.g. 'left-foot contact', inherited from continuity state" })),
  phase_at_end: s.opt(s.str()),
});

export const INTERACTION = s.obj({
  actor_id: s.str(),
  target_id: s.str(),
  relation: s.str(),
  start_ms: s.int("ms"),
  end_ms: s.int("ms"),
});

export const FINAL_FRAME_REQUIREMENTS = s.obj({
  must_be_extendable: s.bool("Default true; false only when the user asked to conclude the event"),
  forbidden_endings: s.arr(ENDING_PATTERN),
  unresolved_motion_required: s.bool(),
  terminal_state_capture: s.bool(),
});

export const VERIFICATION_REQUIREMENT = s.obj({
  dimension: s.str(),
  comparator: s.enum(["gte", "lte", "eq"] as const),
  threshold_mu: s.score(),
  rationale: s.str(),
});

export const B1_VIDEO_IR = s.obj({
  ir_version: s.lit("b1-video-ir/1"),
  objective: s.str({ note: "U-level, in the user's own terms" }),
  scene_mode: SCENE_MODE,
  duration_ms: s.int("ms", { min: 1 }),
  aspect_ratio: s.obj({ w: s.int("count", { min: 1 }), h: s.int("count", { min: 1 }) }),
  target_resolution: s.obj({ width_px: s.int("px", { min: 1 }), height_px: s.int("px", { min: 1 }) }),
  target_frame_rate_mfps: s.int("mfps", { min: 1, note: "23976 = 23.976 fps" }),

  characters: s.arr(CHARACTER),
  identity_constraints: s.arr(IDENTITY_CONSTRAINT),

  environment: s.obj({ description: s.str(), spatial_layout: s.str() }),
  depth_layers: s.arr(s.obj({ index: s.int("count", { min: 0 }), description: s.str() })),
  foreground_elements: s.arr(ELEMENT),
  midground_elements: s.arr(ELEMENT),
  background_elements: s.arr(ELEMENT),
  props: s.arr(ELEMENT),

  lighting: s.obj({ description: s.str(), key_direction: s.opt(s.str()) }),
  atmosphere: s.obj({ description: s.str() }),
  material_behavior: s.arr(s.obj({ material: s.str(), behavior: s.str() })),

  camera_state: CAMERA_STATE,
  camera_motion: s.arr(CAMERA_MOTION),
  lens_behavior: s.obj({ description: s.str(), focus_behavior: s.opt(s.str()) }),

  subject_motion: s.arr(SUBJECT_MOTION),
  secondary_motion: s.arr(s.obj({ element_id: s.str(), behavior: s.str() })),
  interaction_graph: s.arr(INTERACTION),
  physics_expectations: s.arr(s.obj({ subject: s.str(), expectation: s.str() })),
  animation_timing: s.obj({ description: s.str(), beat_ms: s.opt(s.int("ms")) }),
  rhythm: s.obj({ description: s.str() }),

  audio_state: s.obj({
    present: s.bool(),
    description: s.opt(s.str()),
    phase_note: s.opt(s.str()),
  }),
  narrative_state: s.obj({ description: s.str(), unresolved: s.arr(s.str()) }),
  visual_style: s.obj({ description: s.str() }),

  reference_bindings: s.arr(REFERENCE_BINDING),
  continuity_constraints: s.arr(s.obj({ constraint: s.str(), source_segment_id: s.opt(s.str()) })),
  negative_constraints: s.arr(s.obj({ forbid: s.str(), rationale: s.str() })),
  final_frame_requirements: FINAL_FRAME_REQUIREMENTS,
  verification_requirements: s.arr(VERIFICATION_REQUIREMENT),

  origin: s.obj(
    { fields: s.arr(s.obj({ path: s.str(), origin: ORIGIN })) },
    "Per-field U/M/P/E attribution. Excluded from ir_digest; unattributed fields are UNKNOWN, never U.",
  ),
});

export type B1VideoIR = Infer<typeof B1_VIDEO_IR>;
export type ReferenceBinding = Infer<typeof REFERENCE_BINDING>;

export const IR_SCHEMA = emit("b1-video-ir", "B1_VIDEO_IR", B1_VIDEO_IR);
