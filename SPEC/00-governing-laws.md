# Governing Laws

Status: **NORMATIVE**. These laws bind every component. A component that violates one is defective
regardless of whether its tests pass.

## L1 — The separation law

These are distinct concepts and are never collapsed into one value, one field, or one variable:

```
USER_INTENT ≠ REFERENCE_MEDIA ≠ PROMPT ≠ SCENE_SPECIFICATION ≠ GENERATION_PLAN
  ≠ PROVIDER_REQUEST ≠ PROVIDER_RECEIPT ≠ GENERATED_MEDIA ≠ OBSERVED_MEDIA_STATE
  ≠ VERIFIED_OUTPUT ≠ CONTINUITY_STATE ≠ FINAL_DELIVERY
```

and

```
MODEL_CAPABILITY ≠ ORCHESTRATION_CAPABILITY ≠ SYSTEM_CAPABILITY
```

The system does not modify any render model's weights and never claims to. What it claims is that
orchestration, reference preparation, state persistence, closed-loop evaluation and targeted repair
can obtain better usable results than a naive single generation request — a claim that must be
*measured*, never asserted.

## L2 — Origin ≠ Authority ≠ Executor ≠ Effect

Every consequential decision carries an origin:

| Code | Meaning |
|---|---|
| `U` | User-literal — explicitly requested, stated, constrained, or authorized by the user |
| `M` | Model-derived — derived by the system because it materially advances `U` |
| `P` | Platform-generated — produced by the surrounding platform, runtime, provider, or toolchain |
| `E` | Emergent — arose through interaction; no single actor cleanly explains it |

Where something came from never determines who authorized it, who executed it, or what actually
changed. These are four independent dimensions and every record carries all four.

## L3 — Receipt ≠ Observed effect ≠ Objective postcondition

A provider returning success means `PROVIDER_TASK_SUCCEEDED`. It does not mean
`USER_OBJECTIVE_SUCCEEDED`.

After every generation: retrieve the media, inspect the media, evaluate the postconditions,
*then* classify. Never in the other order, and never skipping a step.

```
OUTCOME := VERIFIED | PARTIAL | FAILED | IN_DOUBT | NOT_EXECUTED
```

Missing media, unretrievable media, or an unverifiable result is `IN_DOUBT`. Never `VERIFIED`.
A resource existing does not prove it was created correctly; a deployment existing does not prove
it works; a receipt does not prove an effect.

## L4 — PLAN_READY ≠ EXECUTION_AUTHORIZED

Analysis, exploration, decomposition, inspection, planning, simulation, comparison, strategy
construction, validation and preparation proceed autonomously when they advance `U`. Thinking
requires no gate.

Every *persistent effect* requires separate explicit authorization bound to an authority envelope.
See `40-authority-gate.md`. Planning-time approval is not effect-time approval.

## L5 — Epistemic classes

| Class | Meaning |
|---|---|
| `VERIFIED` | Adequate current evidence supports the claim |
| `WORKING_ASSUMPTION` | Provisionally useful for reasoning; not proven |
| `UNKNOWN` | Required information is unavailable or inaccessible |
| `IN_DOUBT` | Evidence exists but is conflicting, stale, partial, or unattributable |

`UNKNOWN` remains `UNKNOWN`. A field whose value could not be established is never filled with a
plausible guess. Every capability record distinguishes "this provider does not support X" from
"we do not know whether this provider supports X" — these are different facts with different
consequences.

## L6 — The evidence transfer law

Evidence gathered from one provider is a **hypothesis** about another, never a conclusion.

```
SORA_EVIDENCE → hypothesis → provider experiment → observed result → provider-specific evidence
```

"Worked in Sora" never becomes "will work in Seedance". Every evidence record carries
`TRANSFERABILITY` and `FAILURE_CASES` precisely so this collapse cannot happen quietly.
See `70-provider-routes.md` and the evidence stores.

## L7 — The convergence law

`Continue`, `beyond`, `transcend`, `breakthrough`, `perfect` and `optimize` set a *search
direction*. They are not objectives, permissions, proof, or licence for unbounded recursion, and
they are never themselves a source of authority.

Each iteration must earn its replacement of the current verified best:

1. All `U`-level invariants preserved.
2. At least one material defect resolved, or a structural capability demonstrably improved.
3. No larger unresolved regression introduced.
4. The improvement is causally attributable to the change.
5. The improvement is evidenced, not asserted.
6. The candidate did not merely become longer.

Stop when a complete audit finds no new material defect and no demonstrated improvement, and
return `CONVERGED_FOR_CURRENT_OBJECTIVE_AND_EVIDENCE`. Stopping because of a token, time, tool or
access limit is **not** convergence and is reported as `NOT_CONVERGED — <limit>`.

## L8 — The anti-fabrication law

Never fabricate facts, evidence, capabilities, approvals, resources, dependencies, execution,
persistence, results, tests, proof, or certainty.

The strongest specific form of this law, and the one most likely to be tested in practice: **if no
render provider is authorized, no generation has occurred.** Produce the complete generation
package, stamp `EXECUTION_STATUS := NOT_EXECUTED`, and say so plainly. A synthesized placeholder
video, a plausible-looking receipt, or a quality score computed over media that was never generated
are all the same violation.

## L9 — The anti-ceremony law

Complexity must earn its existence. More components, languages, agents, abstractions, services,
iterations, or output are not improvement.

Applied to the fourteen-language invariant: every language owns a genuine responsibility, and the
test is removal — if deleting a component changes nothing architecturally, it was ceremony.
See `80-participation-invariant.md`.

## L10 — The P/E anomaly law

When platform or emergent processes create, modify, expose, or persist consequential state with no
corresponding authorized action: detect it, preserve its evidence and causal context, classify the
origin `P`/`E`/`UNKNOWN`, and mark the state `IN_DOUBT`.

Existence is never retroactively read as authorization. State is never silently normalized into
user-approved state because it happens to be there.
