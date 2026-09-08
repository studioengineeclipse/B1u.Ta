# B1_VIDEO_IR — Canonical Intermediate Representation

Status: **NORMATIVE**. Authored as TypeScript types in `contracts/src/`, from which JSON Schema is
generated for every other language. The TypeScript is the source; the schema is derived; no
language hand-writes its own copy of the shape.

## 1. Position in the pipeline

```
USER_INTENT + REFERENCE_MEDIA
        │  (analysis, separation)
        ▼
   B1_VIDEO_IR          ← canonical creative state, provider-neutral, owned by B1
        │  (compilation)
        ├──────────────► SEEDANCE_REQUEST
        ├──────────────► NETA_REQUEST
        └──────────────► OTHER_PROVIDER_REQUEST
```

The provider prompt is **compiled from** the IR. The prompt is not the canonical state, and
provider-specific syntax never contaminates the IR. This is what makes controlled comparison
possible: same intent, same references, different render engines.

## 2. Numeric discipline

Every quantity obeys `20-b1-canon-1.md` §4 — integers with unit suffixes, no floating point
anywhere in the IR. `duration_ms`, `frame_rate_mfps`, `pan_mdeg`, `dolly_mm`, `width_px`,
`confidence_ppm`. A bare numeric field name in the IR is a defect.

## 3. Structure

```
B1_VIDEO_IR := {
  ir_version          : "b1-video-ir/1"
  objective           : string              // U-level, in the user's terms
  scene_mode          : SceneMode
  duration_ms         : int
  aspect_ratio        : { w: int, h: int }  // exact ratio, not a decimal
  target_resolution   : { width_px: int, height_px: int }
  target_frame_rate_mfps : int

  characters          : Character[]
  identity_constraints: IdentityConstraint[]

  environment         : Environment
  spatial_layout      : SpatialLayout
  depth_layers        : DepthLayer[]
  foreground_elements : Element[]
  midground_elements  : Element[]
  background_elements : Element[]
  props               : Prop[]

  lighting            : Lighting
  atmosphere          : Atmosphere
  material_behavior   : MaterialBehavior[]

  camera_state        : CameraState
  camera_motion       : CameraMotion[]
  lens_behavior       : LensBehavior

  subject_motion      : SubjectMotion[]
  secondary_motion    : SecondaryMotion[]
  interaction_graph   : Interaction[]
  physics_expectations: PhysicsExpectation[]
  animation_timing    : AnimationTiming
  rhythm              : Rhythm

  audio_state         : AudioState
  narrative_state     : NarrativeState
  visual_style        : VisualStyle

  reference_bindings  : ReferenceBinding[]   // see 30 §Reference semantics
  continuity_constraints : ContinuityConstraint[]
  negative_constraints: NegativeConstraint[]
  final_frame_requirements : FinalFrameRequirements
  verification_requirements : VerificationRequirement[]

  origin              : OriginMap            // per-field U/M/P/E attribution
}
```

`SceneMode := "single_shot" | "continuation" | "extension" | "variation" | "repair"`.

## 4. Origin attribution

`origin` maps IR field paths to `U`/`M`/`P`/`E` (law L2). The user asking for a cinematic tracking
shot is `U`; the system deriving reference stabilization to achieve it is `M`; a provider silently
altering cloud state is `P`; unexpected motion arising from generation is `E`.

Attribution is per-field, not per-document, because a single IR routinely mixes all four. An
unattributed field defaults to `UNKNOWN` — never to `U`.

## 5. Reference semantics

Every reference carries exactly one explicit role. A reference never silently dominates dimensions
it was not bound to.

```
ReferenceRole :=
  CHARACTER_IDENTITY | FACE_IDENTITY | BODY_DESIGN | COSTUME | ENVIRONMENT | OBJECT
  | STYLE | COLOR | COMPOSITION | CAMERA | MOTION | ANIMATION_TIMING | POSE | ACTION
  | VIDEO_CONTINUITY | AUDIO | OTHER_EXPLICIT_ROLE
```

```
ReferenceBinding := {
  reference_id  : string
  media_digest  : string        // b1c1: digest of the referenced media bytes
  role          : ReferenceRole
  role_detail   : string?       // required when role == OTHER_EXPLICIT_ROLE
  weight_ppm    : int           // 0..1000000
  applies_to    : string[]      // IR paths this reference is permitted to influence
  rationale     : string        // which requirement this reference serves
  origin        : Origin
}
```

`applies_to` is the enforcement mechanism for the no-silent-dominance rule: a reference bound as
`MOTION` that lists only motion paths cannot legally influence character identity. The Swift
reference engine (`engine/swift`) checks these boundaries and reports conflicts where two
references claim overlapping authority over the same path.

A reference is never attached merely because it exists. `rationale` is mandatory: each reference
serves an identified requirement or it is not bound.

## 6. Final frame requirements — extension-safe endings

Unless the user explicitly asked to conclude the event, a segment ends in an **extendable state**.

```
FinalFrameRequirements := {
  must_be_extendable : bool          // default true
  forbidden_endings  : EndingPattern[]
  unresolved_motion_required : bool  // default true
  terminal_state_capture : bool      // default true
}

EndingPattern := "arbitrary_freeze" | "celebration" | "pose" | "fade_out" | "hard_stop"
               | "unexplained_camera_halt" | "artificial_reset" | "neutral_object_reset"
```

Active causal motion is preserved into the terminal frames. Enough state must survive in the final
frames to continue naturally. The Kotlin continuity engine validates this and rejects a segment
whose ending forecloses continuation when `must_be_extendable` is set.

## 7. Identity

```
ir_digest = B1_DIGEST(ir_without_origin_map)
```

The origin map is excluded from the IR digest so that re-attributing provenance does not change
scene identity — two IRs describing the same scene are the same scene even if one has richer
attribution. Provenance changes are tracked in the ledger, which is where they belong.
