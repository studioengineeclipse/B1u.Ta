# B1-CANON-1 — Canonical Serialization and Digest

Status: **NORMATIVE**. Every one of the fourteen languages implements this and must agree.

This is the keystone of the architecture. Every digest in the system — IR identity, authority
envelope binding, ledger chain links, continuity signatures, verified-best identity — is a
B1-CANON-1 digest. If two languages disagree here, the system has no shared truth.

## 1. Why this profile exists

The obvious approach — "serialize JSON and hash it" — fails across fourteen languages for two
reasons that are well documented and not hypothetical:

1. **Floating-point formatting diverges.** ECMAScript's `Number::toString` shortest-round-trip
   output, C's `printf("%.17g")`, Java's `Double.toString`, Python's `repr`, and Ryu/Grisu
   implementations do not agree on the shortest representation of every double. One divergent
   digit destroys the digest.
2. **Key ordering diverges.** Byte order, code-point order, and UTF-16 code-unit order differ for
   non-ASCII keys and for anything above the BMP.

B1-CANON-1 removes both failure classes by construction rather than by hoping implementations
agree.

## 2. Definition

B1-CANON-1 is a **restricted profile of RFC 8785 (JSON Canonicalization Scheme)**. A document is
B1-CANON-1-canonical if it satisfies RFC 8785 *and* the additional restrictions below. The
restrictions only ever *narrow* what is legal, so any correct RFC 8785 implementation produces
correct B1-CANON-1 output for a legal document.

### R1 — Integers only (no floating point)

Every JSON number in a canonical document **MUST** be an integer in the closed range
`[-9007199254740991, 9007199254740991]` (±(2^53 − 1)).

Non-integer numbers, exponent notation, `-0`, `NaN`, and `Infinity` are **forbidden**. A document
containing one is not canonicalizable; implementations **MUST** reject it with
`B1_ERR_NONINTEGER_NUMBER` rather than rounding, coercing, or truncating.

Serialization of an integer is its shortest decimal form: an optional `-` for negatives, then
digits with no leading zero (the single digit `0` excepted). Every language's integer-to-string
agrees on this — that is the entire point.

### R2 — ASCII member names

Object member names **MUST** match `^[A-Za-z0-9_$.-]{1,64}$`.

Every permitted character is below U+0080, so byte order, code-point order, and UTF-16 code-unit
order are provably identical — "sort the keys" means the same thing in all fourteen languages, with
no surrogate-pair reasoning and no locale-sensitive collation. Members are sorted ascending by that
order. Duplicate member names are rejected with `B1_ERR_DUPLICATE_KEY`.

`$`, `.` and `-` are included because the restriction is about *ordering ambiguity*, which only
non-ASCII names introduce, and excluding them would make the profile unable to canonicalize the
system's own JSON Schema documents (`$schema`, `$id`, `x-b1-unit`). A canonicalization profile that
cannot digest the contract it belongs to is not usable — that defect was found by the build and
fixed here rather than worked around at the call site.

String *values* are unrestricted Unicode — only names are constrained.

### R3 — String escaping

Per RFC 8785 §3.2.2.2. Escape exactly: `"` → `\"`, `\` → `\\`, U+0008 → `\b`, U+0009 → `\t`,
U+000A → `\n`, U+000C → `\f`, U+000D → `\r`. Any other control character below U+0020 → `\u00xx`
with **lowercase** hex. Every other character is emitted literally as UTF-8. Do not escape `/`.
Do not use `\uXXXX` for anything that has a literal form.

**Surrogate pairs in `\u` escapes.** A `\uD800`–`\uDBFF` escape **MUST** be immediately followed by
a `\uDC00`–`\uDFFF` escape, and the pair decodes to the single scalar it denotes. A high surrogate
not followed by a low one, and a low surrogate appearing alone, are both rejected with
`B1_ERR_INVALID_UTF8`.

This is stated explicitly because it is a real divergence, not a theoretical one: an
implementation whose character constructor yields lone surrogates (Python's `chr`) leaves two
unpaired code points where a UTF-16-native implementation joins them into one astral scalar. Both
consider the document well-formed and produce different digests. The consequence is normative:
`{"a":"🎬"}` and `{"a":"🎬"}` **MUST** produce the same digest.

Lone surrogates are rejected with `B1_ERR_INVALID_UTF8`.

### R4 — No insignificant whitespace

No space, tab, or newline between any tokens. `{"a":1,"b":[2,3]}`.

### R5 — Literals and arrays

`true`, `false`, `null` lowercase. Array element order is significant and preserved.

A literal denotes **a value**, never a position. This reads as too obvious to state, and it is
stated because an implementation got it wrong in a way nothing detected: a parser returned the
offset at which the literal ended, so `{"a":true}` and `{"a":9}` canonicalized alike and `[true]`
and `[ true]` did not. Whatever else is true of a canonicalizer, two documents differing only in
insignificant whitespace **MUST** produce the same digest, and two documents differing in a value
**MUST NOT**.

### R6 — Input must be valid UTF-8

The input is a byte sequence. A byte sequence that is not well-formed UTF-8 **MUST** be rejected
with `B1_ERR_INVALID_UTF8`. Malformed bytes **MUST NOT** be replaced with U+FFFD, and validity
**MUST** be established before parsing — a decoder that substitutes has already destroyed the
evidence by the time any other rule runs.

Overlong encodings, truncated sequences, and surrogate code points encoded as if they were scalars
(`ED A0 80`) are all malformed and all rejected.

This is normative because three implementations failed it — C#, Kotlin and TypeScript, the last of
which owns the contract every other language consumes. Each decoded stdin with the runtime's
default, which is lossy, so `{"a":"\xff"}` and `{"a":"\xfe"}` — two different documents — were
accepted and given **the same digest**, while eleven implementations rejected both. A digest that
survives corruption has stopped identifying the bytes it names, which is the one thing a digest is
for. Note the shape of the failure: nobody wrote a lossy decoder on purpose. Three languages'
convenient default *is* lossy, and the convenient call is the one that gets written.

## 3. Digest

```
B1_DIGEST(value) = lowercase_hex( SHA-256( B1_CANON_1(value) as UTF-8 bytes ) )
```

64 lowercase hex characters. When carried as an identifier in a record it is prefixed: `b1c1:` +
the 64 hex characters. The prefix is **not** part of the hashed input; it labels the algorithm so a
future B1-CANON-2 cannot be silently confused with this one.

`core/c/libb1sig` is the **normative implementation**. Where any other implementation disagrees
with `libb1sig` on a legal document, the other implementation is wrong by definition.

## 4. Unit conventions — how the no-float rule stays livable

Physical quantities are carried as integers with a suffix that names the unit. This is not
cosmetic: it is what makes R1 satisfiable for a system that describes camera motion and timing.

| Suffix | Unit | Example |
|---|---|---|
| `_ms` | milliseconds | `duration_ms: 5000` (5 s) |
| `_ppm` | parts per million, 0..1000000 | `confidence_ppm: 875000` (0.875) |
| `_mu` | milli-units, 0..1000 | `prompt_adherence_mu: 820` (0.82) |
| `_mdeg` | milli-degrees | `pan_mdeg: 15500` (15.5°) |
| `_mm` | millimetres | `dolly_mm: 1500` (1.5 m) |
| `_mfps` | milli-frames per second | `frame_rate_mfps: 23976` (23.976 fps) |
| `_px` | whole pixels | `width_px: 1920` |

A field carrying a physical quantity **MUST** use one of these suffixes. A reviewer seeing a bare
numeric field name in the IR should treat it as a defect.

## 5. Conformance protocol

Every language ships a `conform` entrypoint. Contract:

```
stdin  : a JSON document (the fixture)
stdout : <64 lowercase hex digits>\n
exit   : 0 on success; non-zero with a B1_ERR_* token on stderr for a rejected document
```

The token **MUST** appear on stderr as a line of its own. A harness **MUST** locate that line rather
than assume it is the first: runtimes emit banner text on stderr that has nothing to do with the
document — the JVM's `JAVA_TOOL_OPTIONS` notice is the case that caught this — and reading line one
attributes that noise to the implementation, reporting a correct rejection as a divergence. Nothing
other than the token line is interpreted.

`conformance/fixtures/` holds the corpus. `conformance/expected.json` maps each fixture to its
digest and, for negative fixtures, to the required `B1_ERR_*` token. `rake conform` runs every
available language against every fixture and fails on any divergence.

The corpus deliberately includes documents designed to break naive implementations: nested empty
containers, keys that sort differently under different orderings, strings with control characters
and astral-plane scalars, integers at the ±(2^53 − 1) boundary, and negative fixtures for every
`B1_ERR_*` class.

## 6. Error tokens

| Token | Meaning |
|---|---|
| `B1_ERR_NONINTEGER_NUMBER` | A number was not an integer, or fell outside ±(2^53 − 1) |
| `B1_ERR_KEY_SYNTAX` | A member name violated R2 |
| `B1_ERR_DUPLICATE_KEY` | The same member name appeared twice in one object |
| `B1_ERR_INVALID_UTF8` | Malformed UTF-8 or a lone surrogate |
| `B1_ERR_DEPTH` | Nesting exceeded 64 levels |
| `B1_ERR_PARSE` | Not well-formed JSON |

Rejection is always explicit. An implementation that silently repairs a document is broken:
a repaired document produces a digest that no other implementation will reproduce, which converts
a loud failure into a silent divergence.

**Precedence between tokens is deliberately unspecified.** A document may violate more than one
rule, and implementations check rules in whatever order their structure makes natural: an invalid
byte inside a 70-deep array draws `B1_ERR_DEPTH` from six implementations and `B1_ERR_INVALID_UTF8`
from eight. All fourteen reject it, which is the property that matters; no implementation is wrong.

The consequence is a rule for the corpus, not for implementations: **a negative fixture MUST violate
exactly one rule**, because `expected.json` records one token per fixture and a two-defect document
would have it recording an arbitrary choice as though it were the contract.

## 7. Corpus coverage

Agreement on the documents in the corpus says nothing about the documents that are not.

Two CRITICAL defects — the literal-as-position bug in R5, the lossy decoding in R6 — survived 364
green conformance checks across fourteen implementations. Neither was subtle. Both were invisible
for the same reason: the corpus contained no `true`, no `false` and no `null`, and no byte sequence
that was not already valid UTF-8. The checks that existed all passed, and they were checking the
wrong 26 documents.

So the corpus **MUST** satisfy a declared coverage criterion, and that criterion **MUST** be
checked rather than remembered:

- every value form the profile admits — object, array, string, integer, `true`, `false`, `null` —
  appears in at least one positive fixture;
- every `B1_ERR_*` class in §6 is the expected result of at least one negative fixture;
- fixtures declared equivalent (differing only in insignificant whitespace, say) carry the same
  digest in `expected.json`.

`conformance/coverage.json` declares it; `tools/coverage.py` checks it; `rake conform:coverage` runs
it and `rake verify` includes it. Exit 4 is a coverage gap, which is a verdict rather than a
malfunction.

What this cannot do is decide what is worth covering — that judgement lives in `coverage.json` and
will be incomplete again. The claim it supports is "every category we have named is present", never
"every category exists". That is a smaller claim than it looks, and it is the only one available.
