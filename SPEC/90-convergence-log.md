# Convergence Log

The audit record required by `00-governing-laws.md` L7. Each entry records a defect, what resolved
it, and — the part that matters — **what found it**.

That last column is the honest test of whether the verification apparatus does anything. A defect
found by reading the code says the reviewer was careful. A defect found by a test, a build, or a
cross-implementation check says the apparatus works. Every entry below is the second kind.

## Pass 01 — initial construction

Baseline: empty repository. Candidate: the system at `549b21f` plus the integration work in this
pass.

### Defects found and resolved

| # | Found by | Defect | Resolution |
|---|---|---|---|
| 1 | Schema generation failing | R2's charset could not canonicalize the system's own JSON Schema documents (`$schema`, `$id`, `x-b1-unit`). A canonicalization profile that cannot digest the contract it belongs to is unusable. | Widened R2 to `[A-Za-z0-9_$.-]`. The rationale is untouched: the restriction exists to remove *non-ASCII* ordering ambiguity, and every added character is ASCII. |
| 2 | Cross-implementation check | Python rejected `"🎬"` — a valid surrogate pair — where TypeScript accepted it and produced the same digest as the literal emoji. Both considered the document well-formed and disagreed on its meaning: a silent divergence, the exact class the corpus exists to catch. | Surrogate pairs joined at parse time in every implementation. Fixtures `unicode-escape-pair` and three lone-surrogate negatives added. `SPEC/20 R3` now states it normatively. |
| 3 | `rake conform:bless` | `B1_ERR_RE` was `[A-Z_]+`, which does not match the `8` in `B1_ERR_INVALID_UTF8`. Correct rejections scored as "language unavailable". | Added `0-9`. Noted because the failure *understated* results rather than failing loudly — the more dangerous direction. |
| 4 | `tools/probe.py` | Both harnesses read stderr line 1 as the error token. The JVM's `JAVA_TOOL_OPTIONS` banner sits there, so 15 correct Java rejections were reported as divergences. | Locate the `B1_ERR_*` line rather than assuming its position. `SPEC/20 §5` now requires this of any harness. |
| 5 | Kotlin self-test (`NullPointerException`) | A JVM initialization cycle: the companion's source list was built while the object singletons it references were still initializing, so it held nulls. `all.size == 6` passed while every element was null. | Deferred with `by lazy`. Worth noting that the size assertion passed — only dereferencing caught it. |
| 6 | C kernel test | The tonal term used bin-wise L1 over luma histograms. Buckets have hard edges, so a uniform exposure shift moves all the mass and scores as a total tonal break — a continuous shot that merely got brighter read as discontinuous. | Replaced with 1-D Earth Mover's Distance over cumulative histograms, which scores by how far mass moved. Structural change now dominates exposure change (145 vs 37 milli-units) as intended. |
| 7 | `rake test` output | The suite summary matched the first count-shaped string in the output. Cargo prints one `test result` line per binary, most with zero tests, so Rust reported "0 tests" while running 15. A summary that can say zero for a passing suite hides the empty run it exists to reveal. | Per-framework extraction. |
| 8 | Reading `b1 plan` output | The reference stage reported "0 binding(s) admissible" — it was counting findings, not bindings, and so could not distinguish a clean set of three from an IR that bound none. | Swift now returns `bindings_checked`. Absence of findings is not evidence of admissibility without it. |
| 9 | .NET build | `Convert.ToHexStringLower` is .NET 9+; the project targets net8.0. | `ToHexString(...).ToLowerInvariant()`. Lowercase is normative, so the case is forced rather than assumed. |
| 10 | **Integration audit** | **The trusted core was built, tested and conformant but not wired in.** `b1 plan` emitted packages and wrote no ledger record; `state/ledger.jsonl` did not exist; `check_at_effect_time` had no caller outside its own tests; Swift's reference analysis ran correctly and the pipeline never called it. The repository was in violation of its own `SPEC/30`. | `b1ledger append` and `b1ledger gate` added; the pipeline now checks reference roles before compiling, consults the gate for the provider call, and appends a sealed record per run. |

### Changes rejected

| Change considered | Why rejected |
|---|---|
| Gate the package write and the ledger append behind an authority envelope | Does not terminate: recording an action would require authorizing the recording. Resolved instead by stating the carve-out narrowly in `SPEC/30 §3a` — local append-only audit state and derived planning artifacts — and consulting the gate where the effect actually reaches outside. |
| Bind Rust's canon to `libb1sig` over the C ABI | Would make Rust's conformance a restatement of C's rather than a check on it. The trusted core is the last place to want a single point of agreement. C++ links it, because there the alternative is a genuine duplicate implementation. |
| A second canonicalizer in C++ and Kotlin so all fourteen are "independent" | Duplicating logic in a language that can call the original directly, to improve a number. `SPEC/17` forbids it. Recorded honestly as `via_c_abi` and `via_jvm` instead, so the participation report does not overstate what their agreement proves. |
| Seed the evidence stores with illustrative records | A fabricated observation is indistinguishable from a real one once it is in the store. The stores ship empty, which is the true state. |
| ffmpeg-based media ingestion | Would make the analyzer the one component unverifiable from a cold offline clone. Raw Y4M/PPM instead. |

### Regression check

Against the previous verified best (`549b21f`), per `SPEC/50 §5`:

- **Improved:** causal traceability (runs are now recorded), authority separation (the gate is
  consulted rather than assumed), verification strength (four new trusted-core tests; the reference
  check now gates package emission).
- **Regressed:** none measured.
- **Attribution:** the integration work in defect 10, which is what the audit was looking for.
- **Verdict:** RETAIN.

### Stop reason

A complete pass over the built system found no further material defect that the existing apparatus
could demonstrate. The pass was not cut short by a token, time, tool or access limit.

### Status

`CONVERGED_FOR_CURRENT_OBJECTIVE_AND_EVIDENCE`

This claim is bounded, and the bound is the point. It says: under the current objective, the
available evidence, and this environment, no further improvement is demonstrable. It does not say
the system is correct, complete, or finished.

What it explicitly does not cover:

- **No provider contract has ever been observed.** Every emitted request is `CONTRACT_UNVERIFIED`,
  every unobserved capability field is `UNKNOWN`, and both evidence stores are empty. The largest
  open question about this system cannot be answered from here.
- **The generation half of the closed loop has never run.** Ingestion, analysis, scoring and
  verification are `NOT_EXECUTED` because there is no media. They are implemented and tested against
  synthetic input; they have never seen a generated frame.
- **Semantic identity remains a proxy.** The analyzer measures structural and tonal similarity, and
  every score derived from it says so.

The next pass cannot begin until a provider is authorized and its contract verified. Convergence
here is convergence of the orchestration fabric, not of the system's purpose.

---

## Pass 02 — contract enforcement

Baseline: `8986940` (pass 01's verified best). Candidate: this pass.

Pass 01 returned `CONVERGED_FOR_CURRENT_OBJECTIVE_AND_EVIDENCE`, and that claim was bounded to
*its* objective and evidence. Pass 02 audited dimensions pass 01 had not — schema consumption,
adversarial input at the append boundary, and whether asserted claims had actually been tested —
and found a defect pass 01's own change had introduced.

### Defects found and resolved

| # | Found by | Defect | Resolution |
|---|---|---|---|
| 11 | Adversarial input at the append boundary | **A record could claim VERIFIED with nothing behind it.** `seal_and_append`, added in pass 01, checked 9 fields by a hand-written list. A record with `receipt`, `observed_effect` and `objective_postcondition` entirely absent was accepted, sealed, chained, and verified as intact. Law L3's mechanism is that those three are *separately present*; absent, the mechanism is gone. Every pass-01 test used the typed `Record` path, which cannot produce this. | The generated schema is now enforced at the boundary; all 27 required fields are checked. The exact document is refused, naming all 15 absences. |
| 12 | Grepping for consumers | **Nine generated schemas, zero consumers.** The contract was published and enforced by nobody, so each component carried its own idea of validity — and two had already drifted 18 fields apart. | `SPEC/25-b1-schema-1.md` + `core/rust/src/schema.rs`; the schema is read at runtime, so validity has one definition. |
| 13 | Writing the negative test for defect 12 | **The unknown-keyword rule was weaker than claimed.** Schema defects were detected only while walking the *document*, so an unknown keyword on a field nothing populates was never reached — the validator would keep reporting valid over a constraint it never checked, which is the exact silent weakening the rule exists to prevent. | `scan_schema` walks the whole schema independently of the document. A defect in the contract is a property of the contract. |
| 14 | Enforcement, immediately | **`recomputed_envelope_digest` was declared always-a-digest.** When the gate closes because no envelope is bound there is no digest to recompute; the contract asserted something false exactly when the gate does its most important work. | Made nullable. |
| 15 | Enforcement, on the DSL output | **The authoring DSL emitted reference bindings with no `media_digest`,** which the contract required. | The contract was wrong, not the DSL: a scene can be authored before its media exists. Made nullable, with the constraint belonging at the execution boundary instead — an unbound reference cannot be sent to a provider. |
| 16 | Running the new operator paths | **Verdict exit codes disagreed.** `score` returned 4 on rejection while `continuity` and `converge` returned 0, so nothing could branch on a verdict without knowing which component produced it. | Uniform: `4` = negative verdict across all three, matching the authority gate. |
| 17 | Playwright | The dashboard's "opens from `file://` with no build step" was asserted in pass 01 and never tested. | Tested: correct title and heading, three honest empty states, zero JS errors. **No code change** — the claim was true, and is now evidence rather than assertion. |

### Changes rejected

| Change considered | Why rejected |
|---|---|
| Enforce all nine schemas at every boundary the loop crosses | Out of scope for this pass by explicit decision. Each additional validation point is a place a legitimate document can be wrongly refused and needs its own tests; the ledger boundary is where the actual hole was. The other eight remain generated-and-unenforced, recorded as such in `SPEC/25 §6` rather than left to be discovered. |
| Have `seal_and_append` fall back to the old field list when the schema is missing | A fallback to a weaker check is how enforcement quietly stops. `SchemaUnavailable` refuses the append instead. |
| Let `b1 score` default `measurement_basis` to MEASURED | Would turn the operator path into a way to manufacture a quality verdict from typed-in numbers. The field is required, and verdicts on declared input are marked ineligible to become a verified best. |
| Generate a Rust required-field list from the schema at build time | Two artifacts that can drift, which is the problem being fixed. Reading the schema at runtime keeps one definition. |

### Regression check

- **Improved:** epistemic integrity (a record can no longer assert VERIFIED with nothing behind
  it), verification strength (7 new Rust tests; 26 total), interface integrity (the generated
  contract is now load-bearing), output completeness (three components reachable by an operator).
- **Regressed:** none measured. 364 conformance checks and 9 component suites unchanged and green.
- **Attribution:** defects 11–16 individually, each with a test that fails without its fix.
- **Verdict:** RETAIN.

### Stop reason

A complete pass found no further material defect the existing apparatus could demonstrate. Not cut
short by a token, time, tool or access limit.

### Status

`CONVERGED_FOR_CURRENT_OBJECTIVE_AND_EVIDENCE`

Same bound as pass 01, and one observation worth recording: pass 01 converged and was still wrong.
Its convergence claim was honest — no further improvement was demonstrable *by the apparatus it
had*. Defect 11 was invisible because no test constructed a malformed record, and defect 12 because
nothing asked whether the contract was read. Convergence is a statement about what the current
verification can demonstrate, never about what is true.

What remains open is unchanged and unchangeable from here: **no provider contract has ever been
observed.** Eight of nine schemas are enforced nowhere. The generation half of the loop has never
run.
