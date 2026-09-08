# B1-SCHEMA-1 — Contract Validation

Status: **NORMATIVE**. Implemented by `core/rust/src/schema.rs`, enforced at the ledger boundary.

## 1. What this is for

`contracts/` generates JSON Schema for every record type in the system. Before this profile existed,
nothing read those files. The contract was written, published, and enforced by nobody — which meant
each component carried its own idea of what a valid document looked like, and those ideas were free
to drift apart without anything noticing.

They had already drifted. `ledger-record.schema.json` declared 27 required fields; the ledger's
append path checked 9 by a hand-written list. The 18-field gap included `receipt`,
`observed_effect` and `objective_postcondition` — so a record could assert
`present_validity: VERIFIED` with all three absent, seal, chain, and pass verification with nothing
present to contradict it. Law L3's entire mechanism is that those three fields are *separately
present*; if they may be absent, the mechanism is gone.

B1-SCHEMA-1 makes the generated schema the single definition of validity, read at runtime.

## 2. A closed subset, not general JSON Schema

The schemas this profile validates against are emitted by exactly one program: the builder in
`contracts/src/schema.ts`. That makes the keyword set **closed** — a validator does not need to
handle JSON Schema in general, only what the builder can produce.

Validating keywords:

| Keyword | Applies to | Meaning |
|---|---|---|
| `type` | any | `object`, `array`, `string`, `integer`, `boolean`, `null` |
| `properties` | object | per-member schemas |
| `required` | object | member names that must be **present** |
| `additionalProperties` | object | always `false`; any unlisted member is a violation |
| `anyOf` | any | at least one branch must validate (how nullable fields are expressed) |
| `items` | array | schema every element must satisfy |
| `minimum` / `maximum` | integer | inclusive bounds |
| `enum` | string | permitted values |
| `const` | string | the single permitted value |
| `pattern` | string | anchored pattern; see §4 |

Annotations, carried but not validated: `$schema`, `$id`, `title`, `description`, `x-b1-unit`.

`required` means **present**, not merely non-null. A field declared required and nullable must
appear with the value `null`; omitting it is a violation. That distinction is the whole point of
§1 — "we did not record this" and "we recorded that there was nothing" are different claims.

## 3. An unrecognized keyword is an error

Standard JSON Schema **ignores** keywords it does not recognize. This profile **rejects** them.

The inversion is deliberate and is the difference between enforcement and decoration. Under the
standard behaviour, the day the builder learns a new keyword, every existing validator keeps
returning "valid" while silently not checking the new constraint. Nothing fails, nothing warns, and
the contract quietly weakens. Since the schemas and the validator evolve together in one repository,
the correct response to an unknown keyword is to stop and say so.

Error: `B1_SCHEMA_UNKNOWN_KEYWORD`, naming the keyword and its location.

## 4. An unsupported pattern shape is an error

`pattern` is restricted to one anchored shape, which is all the builder emits:

```
^ <literal-prefix>? <char-class> {n} $
^ <literal-prefix>? <char-class> {n,m} $
```

The three patterns in use are `^[0-9a-f]{64}$`, `^b1c1:[0-9a-f]{64}$`, and `^[a-z0-9_-]{1,64}$`.
This is matched directly; no regular-expression engine is required or permitted.

A pattern outside that shape is rejected with `B1_SCHEMA_UNSUPPORTED_PATTERN` rather than skipped.
A validator that passes over a constraint it cannot evaluate is reporting a result it did not
establish — the same failure as a provider receipt standing in for an observed effect.

## 5. Reporting

Validation returns **every** violation, not the first. Each carries its JSON path
(`/action/kind`, `/reference_bindings/2/role`) and what was wrong.

Stopping at the first violation makes fixing a document an iterative guessing game, and — more
importantly here — hides how far a document is from the contract. Three missing fields and thirty
are different situations, and a validator that reports one of each identically is discarding the
signal that distinguishes them.

## 6. Where it is enforced

| Boundary | Schema | Component |
|---|---|---|
| Ledger append | `ledger-record.schema.json` | `core/rust` — `Ledger::seal_and_append` |

Enforcement is at the ledger boundary because that is where records enter tamper-evident history,
and because Rust already gatekeeps that boundary. The schema is read at runtime from
`contracts/generated/`, so the contract has exactly one definition — authored in TypeScript,
enforced in Rust, with no generated Rust to drift out of step.

`b1ledger validate <schema-path>` exposes the validator over IF-1, so any of the fourteen languages
can validate a document without fourteen validators existing (SPEC/80 §6, one authoritative owner).

The remaining eight schemas are generated and **not** currently enforced at any boundary. That is
recorded here rather than left to be discovered: the IR, the generation package, the capability map,
the quality vector, the continuity state and the rest are validated by no component today.

## 7. Error tokens

| Token | Meaning |
|---|---|
| `B1_SCHEMA_MISSING_REQUIRED` | A required member was absent |
| `B1_SCHEMA_TYPE_MISMATCH` | A value had the wrong type |
| `B1_SCHEMA_ADDITIONAL_PROPERTY` | A member appeared that the schema does not declare |
| `B1_SCHEMA_ENUM` | A string was outside its permitted set |
| `B1_SCHEMA_CONST` | A string did not equal its required constant |
| `B1_SCHEMA_RANGE` | An integer fell outside `minimum`/`maximum` |
| `B1_SCHEMA_PATTERN` | A string did not match its pattern |
| `B1_SCHEMA_ANY_OF` | No `anyOf` branch validated |
| `B1_SCHEMA_UNKNOWN_KEYWORD` | The schema used a keyword outside the closed subset (§3) |
| `B1_SCHEMA_UNSUPPORTED_PATTERN` | The schema used a pattern outside the supported shape (§4) |

The last two describe a defect in the **schema**, not the document. They are failures of the
validator's ability to enforce, and are reported as such rather than folded in with document errors.
