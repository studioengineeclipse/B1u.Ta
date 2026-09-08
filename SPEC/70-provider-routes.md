# Provider Discovery, Routes, and Evidence

Status: **NORMATIVE**. Implemented by `engine/go/internal/discovery` and the evidence stores.

## 1. Never assume access

At startup the system determines which execution routes actually exist. It does not infer access
from the presence of a credential, and it does not infer a credential from the presence of a
related one.

| Route | Condition |
|---|---|
| **A — Official Seedance** | Valid official Seedance/BytePlus/Volcengine credentials *and* the required entitlement |
| **B — Neta router → Seedance** | A legitimate `NETA_ROUTER_KEY` or equivalent documented authorization |
| **C — Neta native creative API** | Neta's own `make_video` / `make_image` / asset capabilities |
| **D — Other user-authorized provider** | Capability identified *and* interface verified |
| **E — PLANNING_ONLY** | No rendering provider is authorized |

Route B is **not** implied by Route C. A `NETA_TOKEN` authorizes Neta's own capabilities; it does
not authorize routing to Seedance. Deriving B from a token that grants C is the exact
credential-to-entitlement confusion §2 forbids.

## 2. Credential existence is not entitlement

Holding a credential proves that a credential exists. It does not prove the account has the model,
the quota, the region, or the feature. Entitlement is established by observation — a capability
query that succeeds — or it remains `UNKNOWN`.

## 3. Capability record

```
ProviderCapability := {
  provider_id, auth_method, base_url,
  available_models[], input_modalities[], output_modalities[],
  duration_limits, resolution_limits, reference_limits,
  extension_support, audio_support,
  currently_verified_at_ms, evidence_source,
  contract_status : "VERIFIED" | "CONTRACT_UNVERIFIED" | "UNKNOWN"
}
```

Every field is `UNKNOWN` until observed. A field is never populated from memory, from documentation
the system has not fetched, or from what a similar provider does. `UNKNOWN` remains `UNKNOWN` —
an invented duration limit produces a request that fails at generation time, having consumed the
credits it was supposed to protect.

Model identifiers are discovered from current provider documentation at runtime rather than
hard-coded from stale assumptions.

## 4. Route E — the honest failure mode

When no rendering provider is authorized, the system does **not** fake execution. It produces:

- the exact generation package
- compiled prompts
- reference mappings and role bindings
- continuation state
- evaluation criteria and gate policy
- provider-ready payload specification

and stamps:

```
EXECUTION_STATUS := NOT_EXECUTED
```

This is a complete, useful deliverable — everything except the one step that requires a provider.
It is not a degraded mode to apologise for; it is what integrity looks like when the renderer is
absent. What is forbidden is any artifact that *implies* generation occurred: a placeholder video
presented as output, a synthesized receipt, or a quality vector scored over media that does not
exist.

## 5. Routing policy

Routing follows demonstrated evidence, not preference:

```
IF character/world asset construction required        -> prefer NETA_ASSET_PIPELINE
IF difficult temporal scene + strong reference-video
   requirement AND Seedance authorized                -> prefer SEEDANCE
IF provider A repeatedly outperforms B for a task class-> update PROVIDER_EVIDENCE, prefer A
IF PROVIDER_LIMITATION detected                       -> route to alternate provider
IF no execution route                                 -> PLANNING_ONLY
```

Not every task goes to the strongest temporal renderer. Ta/Neta is a structured creative source —
character fabric, element fabric, world fabric, reference fabric, media fabric — not merely another
video generator, and using it for asset construction is usually better than asking a temporal
renderer to invent consistent assets repeatedly.

## 6. Evidence stores

Two stores, deliberately separate:

`evidence/sora/` — observations supplied by the user or project: prompt/result pairs, motion
observations, continuity successes and failures, camera behaviours, occlusion handling, temporal
artifacts, subject consistency, pacing, material behaviour, reference adherence, regeneration
strategy, extension behaviour, negative-prompt behaviour, shot grammar.

`evidence/provider/` — observations this system made itself, per provider and model.

```
EvidenceRecord := {
  source, observation, confidence_ppm, conditions,
  applicable_provider, transferability, failure_cases[],
  recorded_at_ms, origin
}

transferability := "PROVIDER_SPECIFIC" | "HYPOTHESIS_ONLY" | "CROSS_PROVIDER_OBSERVED" | "UNKNOWN"
```

Sora evidence is **knowledge**. It is not model weights, not a hidden API, not transferable neural
capability, and not proof that another model has Sora's behaviour. It improves orchestration —
prompting, shot construction, continuity technique, failure anticipation — and nothing more.

The transfer path is mandatory and one-directional:

```
SORA_EVIDENCE → hypothesis → provider experiment → observed result → provider-specific evidence
```

A Sora record may enter the pipeline only as `HYPOTHESIS_ONLY` for a different provider. It is
promoted to `PROVIDER_SPECIFIC` for that provider solely by an observed experiment on that
provider. There is no path from "worked in Sora" to "will work in Seedance", and the schema is
shaped so that asserting one requires writing a falsehood into `transferability` rather than merely
omitting a caveat.

## 7. Experimental learning

Each accepted or rejected generation records provider, model, parameters, reference arrangement,
prompt structure, duration, resolution, seed where available, observed strengths and failures,
quality vector, accept/reject, repair performed, and repair result.

Anecdotal success is not universal law. A single good result is one observation; `confidence_ppm`
carries how much weight it earned, and the sample size behind a routing preference is recorded
alongside it.
