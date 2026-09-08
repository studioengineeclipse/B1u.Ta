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

Lone surrogates are rejected with `B1_ERR_INVALID_UTF8`.

### R4 — No insignificant whitespace

No space, tab, or newline between any tokens. `{"a":1,"b":[2,3]}`.

### R5 — Literals and arrays

`true`, `false`, `null` lowercase. Array element order is significant and preserved.

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
