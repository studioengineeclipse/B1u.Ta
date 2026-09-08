# Quality Vector, Hard Gates, and Failure Localization

Status: **NORMATIVE**. Implemented by `engine/python/b1_quality`, fed by `core/cpp/b1-media`.

## 1. Twenty-two dimensions, scored separately

Scores are milli-units, integers `0..1000` (per `20-b1-canon-1.md` §4). A dimension that could not
be measured is `null`, never `0` — "we did not measure it" and "it scored zero" are different
facts, and conflating them is the fastest way to manufacture a false verdict.

```
QualityVector := {
  prompt_adherence_mu, character_identity_mu, temporal_identity_mu, anatomy_mu,
  motion_coherence_mu, motion_complexity_mu, physical_plausibility_mu,
  interaction_correctness_mu, camera_accuracy_mu, spatial_consistency_mu,
  depth_consistency_mu, occlusion_consistency_mu, lighting_consistency_mu,
  material_consistency_mu, environment_consistency_mu, style_consistency_mu,
  reference_adherence_mu, narrative_progression_mu, audio_alignment_mu,
  continuity_start_mu, continuity_end_mu, artifact_severity_mu
}
```

`artifact_severity_mu` is inverted relative to the others: higher is worse. It is kept in the same
vector rather than negated because "severity" is what the analyzer measures, and silently flipping
a sign inside a scoring pipeline is how thresholds end up backwards.

## 2. Hard gates — no averaging over catastrophe

A mean is not a verdict. A candidate with excellent scores everywhere and a destroyed character
identity is not a good candidate; it is a failed one.

```
HardGate := { dimension, comparator: "gte"|"lte"|"eq", threshold_mu, rationale }

accept(candidate) :=
      all hard gates pass
  AND forbidden_event_count == 0
  AND no required dimension is null
```

A `null` in a gated dimension **fails** the gate. Unmeasured is not passed — the gate exists to
require evidence, and admitting an unmeasured dimension would let absence of evidence read as
evidence of adequacy.

Default policy lives in `conformance/policy/gates.json`. A typical set:

```
character_identity_mu   gte 700
continuity_start_mu     gte 750
anatomy_mu              gte 650
artifact_severity_mu    lte 250
forbidden_event_count   eq  0
```

Gate results report **which** gate failed and by how much. "Rejected" without a locus is not
actionable and forces a blind regeneration, which is what §3 exists to prevent.

## 3. Failure localization — classify before regenerating

```
FailureType :=
  IDENTITY_DRIFT | ANATOMY_FAILURE | MOTION_FAILURE | PHYSICS_FAILURE | CAMERA_FAILURE
  | DEPTH_FAILURE | OCCLUSION_FAILURE | LIGHTING_FAILURE | REFERENCE_FAILURE
  | STYLE_FAILURE | TEMPORAL_DISCONTINUITY | OBJECT_PERSISTENCE_FAILURE
  | ENVIRONMENT_DRIFT | AUDIO_FAILURE | NARRATIVE_FAILURE | PROVIDER_LIMITATION | UNKNOWN
```

```
FailureLocalization := {
  failure_type, failing_dimensions[], time_window_ms: {start, end},
  spatial_region: BBox?, evidence[], confidence_ppm, suggested_repair
}
```

Repair targets only the failing dimensions. A prompt that succeeded is not rewritten from scratch
because one dimension failed — the localization exists so the working parts survive the fix.
`UNKNOWN` is a legitimate classification; guessing a failure type to look decisive produces a
repair aimed at the wrong thing.

`PROVIDER_LIMITATION` is distinct from every other type: it means the request was not achievable
by this provider, so repair means *routing*, not prompting. Repeated `PROVIDER_LIMITATION` for a
task class updates provider evidence and changes future routing (`70-provider-routes.md` §5).

## 4. Candidate search

For a difficult segment, evaluate structured variants against the *same* vector:

| Candidate | Emphasis |
|---|---|
| A | conservative continuity |
| B | motion-emphasized |
| C | composition-emphasized |
| D | experimental improvement |

## 5. Regression gate

```
PREVIOUS_VERIFIED_BEST is the baseline.
A NEW_CANDIDATE must demonstrate improvement.
A REGRESSION is rejected.
```

Implemented by `engine/csharp/B1.Convergence`. A candidate replaces the verified best only if it
satisfies every hard gate, improves at least one dimension materially, regresses no dimension past
its gate, and the improvement is attributable to an identified change. "Scored higher on average"
is not sufficient and is explicitly rejected — that is the same averaging error as §2, one level up.

Ties do not replace the baseline. Working behavior is preserved unless an evidenced improvement
supersedes it.

## 6. What the analyzer can and cannot establish

`core/cpp/b1-media` computes signal-level metrics over decoded frames: inter-frame difference
energy, temporal stability, block-level structural change, edge/energy distribution, colour
histogram drift, and frame signature distance.

These are **proxies**. Signal-level continuity is not semantic identity: a metric can say that
frame-to-frame structure is stable, and cannot say that the character is the same person. Every
score derived from a proxy carries `measurement_basis` naming the proxy, so a reader can tell a
measured quantity from an inferred one.

Dimensions with no available proxy — `narrative_progression_mu` without a model, `audio_alignment_mu`
with no audio track — are `null` with `measurement_basis: "UNAVAILABLE"`. That is the honest
output, and per §2 it fails any gate that depends on it rather than quietly passing.
