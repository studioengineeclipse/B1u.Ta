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
| `contracts/` | TypeScript contract — the canonical IR and record types; generates the JSON Schema that Rust enforces at the ledger boundary |
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
| `SPEC/90-convergence-log.md` | The audit record: every defect, and what found it |
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
rake build            # build every language that has a build step
rake test             # every component's own suite
rake conform          # every language against every fixture; fails on any divergence
rake conform:coverage # does the corpus cover every form and every error class?
rake probe            # derive the participation status table from what actually runs
rake verify           # all five
```

And to run the loop and inspect what it recorded:

```sh
b1 discover                                   # capability map and selected route
b1 plan examples/shot-02-continuation.json    # -> a package, and one ledger record
b1ledger verify                               # walk the chain, recomputing every digest and link
b1ledger show                                 # one line per record

b1ledger validate contracts/generated/b1-video-ir.schema.json < examples/shot-02-continuation.json
b1 score examples/quality-vector-sample.json      # hard gates + failure localization
b1 continuity examples/boundary-sample.json       # causal compatibility across a boundary
b1 converge examples/convergence-sample.json      # candidate vs the previous verified best
```

Those three exit `4` on a negative verdict — a rejected candidate or an incompatible boundary is the
component working, not failing, and a caller has to be able to tell the two apart.

A planning run checks reference roles before it compiles, asks the authority gate whether a
provider call is authorized, and appends a sealed record. Under Route E the gate closes, and its
own words become the recorded reason generation did not happen — the gate is asked, not assumed.

The conformance corpus is built to break naive implementations: ASCII ordering traps, 2^53
boundary integers, control characters, astral-plane scalars, and negative fixtures for every error
class. Passing it requires genuinely parsing, validating, sorting, escaping and hashing — not
calling the local `json.dumps` and getting lucky.

Expected digests are **blessed by agreement**: a value is only written to `conformance/expected.json`
when at least two independent implementations produce it. One implementation cannot certify its own
output.

That is still only agreement about the documents in the corpus. Three implementations were wrong
about ordinary documents for two passes — Ruby digested `{"a":true}` and `{"a":9}` alike, three
languages accepted invalid UTF-8, Swift rejected anything with Windows line endings — and 364 green
checks could not have found any of it, because no fixture contained a literal, a malformed byte or a
CR. So the corpus has a declared coverage criterion of its own: `conformance/coverage.json` names
every value form and every error class that must have a fixture, and `rake conform:coverage` fails
when one does not. It cannot decide what is worth covering; it can only stop a named category from
going missing quietly.

## The contract is enforced, not just published

`contracts/` generates JSON Schema; `core/rust` reads it at runtime and enforces it where records
enter the chain. Validity therefore has one definition rather than one per component — which
matters, because it previously had two that disagreed: the schema declared 27 required fields and
the append path checked 9, and the 18-field gap included the three whose separate presence law L3
depends on.

B1-SCHEMA-1 (`SPEC/25`) inverts two JSON Schema defaults on purpose. An unrecognized keyword is an
error rather than ignored, and an unsupported pattern is an error rather than skipped — because a
validator that quietly passes over what it cannot check reports a result it never established.

## Participation status is derived, never claimed

`rake probe` compiles what claims to build, runs what claims to execute, and runs the corpus
against what claims to integrate. The ladder is
`PLANNED → BUILDS → EXECUTES → INTEGRATES → EFFECT_VERIFIED → POSTCONDITION_VERIFIED`, and
`state/participation.json` records the evidence for each language's position on it.

Claiming a status above the evidence is the easiest lie to tell in a polyglot repository, because
nobody checks fourteen toolchains by hand. The probe does.
