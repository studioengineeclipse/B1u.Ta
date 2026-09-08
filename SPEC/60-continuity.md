# Kagenashi Chained Continuity

Status: **NORMATIVE**. Implemented by `engine/jvm/kotlin` (`b1.continuity`).

## 1. The law

```
PREVIOUS_VERIFIED_GENERATED_CLIP  =  HARD TEMPORAL HISTORY
NEW_REFERENCE_MEDIA               =  SOFT FUTURE INFLUENCE
```

`STATE_t+1` derives from `STATE_t`. A later reference may influence unresolved future frames. It
may **not** rewrite verified history unless the user explicitly requests a revision.

This is the rule that makes multi-segment generation coherent rather than a sequence of unrelated
clips that happen to share a prompt. Without it, each new reference silently re-litigates
everything already accepted, and the sequence drifts.

Note the word *verified*: only an accepted, observed, gate-passing segment becomes hard history. A
segment that was generated but never verified has no authority over the future — it is a candidate,
not history.

## 2. Continuity state

Extracted from the terminal frames of each accepted segment:

```
ContinuityState := {
  segment_id, source_record_id,          // which ledger record established this
  subject_positions[], subject_orientations[], body_configuration[],
  velocities[], angular_velocities[],
  active_actions[], contact_states[], carried_objects[],
  clothing_state, hair_state, damage_or_deformation_state,
  environment_state, object_positions[],
  camera_position, camera_orientation, camera_velocity, focal_behavior,
  lighting_state, particle_state, fluid_state,
  audio_phase, narrative_state,
  unresolved_motion[], unresolved_causal_events[],
  final_frame_visual_signature,          // from core/c/libb1sig
  measurement_basis                      // MEASURED | DECLARED | INFERRED | UNAVAILABLE
}
```

`measurement_basis` is not optional bookkeeping. Most of these fields cannot be *measured* from
pixels by this system: `carried_objects` and `narrative_state` are declared by the IR or inferred,
while `final_frame_visual_signature` is genuinely measured. Marking which is which prevents an
inferred value from later being cited as observed evidence — a `DECLARED` velocity is a statement
of intent, and treating it as an observation would let the plan verify itself.

## 3. Causal compatibility

The first frame of the next generation must be causally compatible with the previous terminal
state:

```
compatible(terminal, next_first_frame) :=
     positional drift within tolerance
  AND velocity continuity within tolerance (no unexplained stop or teleport)
  AND contact states preserved or transitioned through a legal event
  AND carried objects still carried, or released through a depicted action
  AND camera position/velocity continuous or cut-justified
  AND lighting continuous or transition-justified
  AND visual signature distance within tolerance
```

A violation is reported as `TEMPORAL_DISCONTINUITY` with the specific violated predicate — not as a
generic mismatch. Knowing that the character teleported is actionable; knowing that "continuity
failed" is not.

Tolerances live in `conformance/policy/continuity.json`, in integer units.

## 4. Continuation priority order

When extending an accepted clip, sources are ranked. A lower-priority source may not contradict a
higher-priority one without explicit user authorization.

| Priority | Source |
|---|---|
| 1 | Verified previous generated clip |
| 2 | Its extracted terminal continuity state |
| 3 | Explicit user continuation instruction |
| 4 | New reference video / image / audio |
| 5 | Style guidance |
| 6 | System-inferred improvements |

Kotlin's sealed hierarchy makes this lattice total: every source is one of exactly six cases and
the resolver's `when` is exhaustive at compile time, so a newly added source type cannot silently
fall through to "no opinion". Conflicts are surfaced as
`ContinuationConflict(higher, lower, contested_field)` and resolved in favour of the higher
priority, with the suppression recorded.

Note that priority 3 — the user's own continuation instruction — sits *below* the verified clip and
its terminal state. This is deliberate and follows from §1: history that has been observed and
accepted is not overridden by a new instruction unless the user explicitly asks for a revision, at
which point the request is a revision (a different action) rather than a continuation.

## 5. Extension-safe endings

Per `10-b1-video-ir.md` §6, a segment ends mid-motion unless the user asked to conclude the event.
The validator rejects terminal frames exhibiting a forbidden ending pattern and reports which
pattern was detected.

The rationale is mechanical, not aesthetic: a clip that ends in an arbitrary freeze, a settled
pose, a fade, or with objects reset to neutral positions has destroyed the state that the next
segment needs to continue from. `unresolved_motion` must be non-empty for an extendable ending —
that is the state the next segment inherits.
