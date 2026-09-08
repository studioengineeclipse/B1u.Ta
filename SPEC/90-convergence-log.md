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
