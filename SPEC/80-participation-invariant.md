# Fourteen-Language Participation Invariant

Status: **NORMATIVE**. Verified by `tools/probe` and `rake conform`.

## 1. Two rules operating simultaneously

**Rule A — Global participation invariant.** Across the total architecture, each of the fourteen
languages owns or materially contributes to at least one genuine architectural responsibility.

**Rule B — Local Ω13 selection.** For each individual work unit, the strongest subset of languages
is selected for *that* unit.

```
14 globally required  ≠  14 locally required
All 14 participate. Ω13 selects locally.
```

Confusing these produces the worst possible architecture: fourteen languages crammed into every
component. Rule A is about the whole; Rule B is about each part.

## 2. Ownership map

| Language | Responsibility | Path |
|---|---|---|
| C | Normative signal kernel: SHA-256, B1-CANON-1 canonicalizer, frame visual signature | `core/c` |
| C++ | Media/temporal analyzer over Y4M/PPM | `core/cpp` |
| Rust | Causal ledger + authority/persistence gate + P/E anomaly detector | `core/rust` |
| TypeScript | Canonical contract ownership; IR types → generated JSON Schema | `contracts` |
| Go | Orchestration daemon, provider discovery, route selection, job graph, `b1` CLI | `engine/go` |
| Python | Quality vector, hard gates, failure localization, evidence statistics | `engine/python` |
| Java | Provider-neutral compiler: IR → provider requests, prompt compilation | `engine/jvm/java` |
| Kotlin | Continuity engine: terminal state, priority lattice, extension-safe endings | `engine/jvm/kotlin` |
| Swift | Reference role algebra: binding, boundary enforcement, conflict detection | `engine/swift` |
| C# | Convergence and regression gate | `engine/csharp` |
| PHP | Evidence library server | `surfaces/php` |
| Ruby | Authoring DSL, Rake polyglot build/verify graph, executive handoff generation | `surfaces/ruby` |
| Dart | Authority envelope presenter | `engine/dart` |
| JavaScript | Zero-build browser review surface | `surfaces/web` |

### On the JavaScript / TypeScript boundary

These are the two most likely to collapse into one role, so the split is explicit. TypeScript owns
*typed contract generation* — it is compiled, runs under Node, and produces the JSON Schema every
other language consumes. JavaScript owns the *review surface* and is deliberately build-free: the
dashboard must open from `file://` with no toolchain, no bundler, and no install step, because a
reviewer inspecting why a candidate was rejected should not first have to build anything. Neither
role can absorb the other without losing a property that was chosen on purpose.

## 3. Meaningful participation

A language does not satisfy Rule A because a file exists in it. For each language:

```
Responsibility → Input → Output → Interface → Dependency → Execution path → Test
   → Observable contribution
```

**The removal test.** If deleting a component produces no relevant architectural change, it was
ceremony and it fails.

Explicitly not participation: hello-world programs, dead modules, unused wrappers, unused packages,
artificial microservices, duplicate implementations of the same logic, dummy FFI bridges, uncalled
scripts, and source files never included in the build.

Where a language is poorly suited to a large responsibility, it gets the smallest *meaningful*
non-ceremonial responsibility that genuinely contributes. Complexity is not manufactured to inflate
a role — that would violate law L9 in the course of satisfying Rule A.

## 4. Status ladder

```
PLANNED → BUILDS → EXECUTES → INTEGRATES → EFFECT_VERIFIED → POSTCONDITION_VERIFIED
```

Status is **derived by `tools/probe`**, never asserted in prose. The probe compiles what claims to
build, runs what claims to execute, and runs the conformance corpus for what claims to integrate.
A language whose toolchain is absent is `PLANNED` with its build command documented — not
`BUILDS` on the grounds that the source looks correct.

Claiming a status above the evidence is the participation-map form of law L8, and it is the
easiest lie to tell in a polyglot repository because nobody checks fourteen toolchains by hand.
That is exactly why the probe does it.

## 5. Conformance — the proof that participation is real

Every language ships a `conform` entrypoint implementing `20-b1-canon-1.md` §5: read a JSON
document on stdin, emit its B1-CANON-1 digest on stdout.

This is not a ceremonial handshake. To pass, an implementation must genuinely parse JSON, enforce
the integer-only rule, enforce the key-syntax rule, detect duplicate keys, sort members, escape
strings per RFC 8785, serialize with no whitespace, and compute SHA-256 over the result — and agree
with C, byte for byte, across a corpus built to break naive implementations. A language that cannot
do this cannot be trusted to hold any part of the canonical state.

`rake conform` runs every language against every fixture and fails on any divergence.

## 6. Interface discipline

Four interface types, kept minimal so fourteen languages do not become fourteen disconnected
systems:

| # | Type | Contract |
|---|---|---|
| IF-1 | JSON over stdio/files | Generated JSON Schema from `contracts/` |
| IF-2 | C ABI (`b1_abi.h`) | Versioned symbols, explicit lifetimes |
| IF-3 | HTTP/JSON on localhost | Go control API, versioned path prefix |
| IF-4 | In-process JVM | Java ↔ Kotlin shared types |

One authoritative owner per domain responsibility. Business logic is not duplicated across
languages to manufacture participation; where two languages touch the same domain, one owns it and
the other consumes its output through one of these four interfaces.
