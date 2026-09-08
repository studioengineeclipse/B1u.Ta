# B1u.Ta — B1μ-DQAS Ω13.9 Multimodal Video Orchestrator

A provider-neutral orchestration and verification fabric for multimodal video generation.

The render model is a **component**. The canonical creative state belongs to B1. Provider receipts
are evidence, not proof. Observed media determines success.

## What this is, and what it is not

This system does not modify any render model's weights and never claims to. What it claims is
narrower and testable: that reference preparation, state persistence, multi-provider routing,
decomposition, closed-loop evaluation, targeted repair, candidate comparison and continuity
preservation can obtain better usable results than a naive single generation request.

That claim is measured, not asserted. See `SPEC/00-governing-laws.md` L1 and L7.

## Current operating mode

**PLANNING_ONLY (Route E).** No render provider is authorized in this environment — no Neta
credential, no Neta router key, no Seedance/BytePlus/Volcengine credential. The system therefore
produces complete, provider-ready generation packages stamped `EXECUTION_STATUS = NOT_EXECUTED`
and does not fabricate execution. Adding a credential and verifying the provider's live API
contract is what moves it to Route A–D; see `SPEC/70-provider-routes.md`.

## Layout

| Path | Contents |
|---|---|
| `SPEC/` | Normative documents. Everything else implements these. |
| `contracts/` | TypeScript contract — the canonical IR and record types; generates the JSON Schema every other language consumes |
| `core/c` | `libb1sig` — normative SHA-256, B1-CANON-1 canonicalizer, frame visual signature |
| `core/cpp` | Media/temporal analyzer |
| `core/rust` | Causal ledger, authority gate, P/E anomaly detector |
| `engine/go` | Orchestration daemon, provider discovery, job graph, `b1` CLI |
| `engine/python` | Quality vector, hard gates, failure localization |
| `engine/jvm/java` | Provider-neutral compiler and prompt compilation |
| `engine/jvm/kotlin` | Continuity engine |
| `engine/swift` | Reference role algebra |
| `engine/csharp` | Convergence and regression gate |
| `engine/dart` | Authority envelope presenter |
| `surfaces/php` | Evidence library server |
| `surfaces/ruby` | Authoring DSL, polyglot build graph, report generation |
| `surfaces/web` | Zero-build review dashboard |
| `conformance/` | The corpus that proves all fourteen languages agree |
| `state/` | Ledger, continuity snapshots, participation status |

## The keystone: B1-CANON-1

Every digest in the system — IR identity, authority envelope binding, ledger chain links,
continuity signatures — is a B1-CANON-1 digest, and all fourteen languages must produce the same
one. Two design decisions make that achievable rather than aspirational:

1. **No floating point** in any digest-bearing field. Durations are milliseconds, ratios are
   parts-per-million, scores are milli-units. Float formatting is where cross-language
   canonicalization normally dies.
2. **ASCII-only member names**, so byte order, code-point order and UTF-16 code-unit order coincide
   and "sort the keys" means one thing everywhere.

`SPEC/20-b1-canon-1.md` is normative; `core/c/libb1sig` is the normative implementation.

## Verifying

```sh
rake build      # build every language that has a build step
rake conform    # every language against every fixture; fails on any divergence
rake probe      # derive the participation status table from what actually runs
rake verify     # all three
```

The conformance corpus is built to break naive implementations: ASCII ordering traps, 2^53
boundary integers, control characters, astral-plane scalars, and negative fixtures for every error
class. Passing it requires genuinely parsing, validating, sorting, escaping and hashing — not
calling the local `json.dumps` and getting lucky.

Expected digests are **blessed by agreement**: a value is only written to `conformance/expected.json`
when at least two independent implementations produce it. One implementation cannot certify its own
output.

## Participation status is derived, never claimed

`rake probe` compiles what claims to build, runs what claims to execute, and runs the corpus
against what claims to integrate. The ladder is
`PLANNED → BUILDS → EXECUTES → INTEGRATES → EFFECT_VERIFIED → POSTCONDITION_VERIFIED`, and
`state/participation.json` records the evidence for each language's position on it.

Claiming a status above the evidence is the easiest lie to tell in a polyglot repository, because
nobody checks fourteen toolchains by hand. The probe does.
