# Causal Ledger

Status: **NORMATIVE**. Implemented by `core/rust/b1-ledger`. Append-only, hash-chained,
tamper-evident.

## 1. What the ledger is for

Law L3 says a receipt is not an effect and an effect is not objective success. The ledger is where
that distinction is *stored* rather than merely stated. Every consequential action produces one
record in which receipt, observed effect, and objective postcondition occupy three separate fields
that can each independently be empty, present, or contradictory.

A record where `receipt = ok` and `observed_effect = null` is not a success. It is
`IN_DOUBT`, and the ledger makes that visually obvious rather than letting it be read as done.

## 2. Record

```
LedgerRecord := {
  seq                : int          // 0-based, strictly increasing, no gaps
  prev_link          : string       // "b1c1:" + digest of previous record, or 64 zeros at seq 0
  record_id          : string       // "b1c1:" + digest of this record's body

  goal               : string       // the Strategic Goal this serves
  derived_need       : string       // why this action, given the goal
  origin             : "U"|"M"|"P"|"E"
  causal_parents     : string[]     // record_ids this action depends on

  authority          : Authority
  authorization_ref  : string?      // envelope_id; null for non-persistent actions
  envelope_digest    : string?      // envelope contents at authorization time
  effect_time_validation : EffectTimeValidation?

  executor           : string       // which component performed it
  execution_identity : string       // which concrete runtime/process/provider instance
  attempt_identity   : string       // which attempt; a retry is NOT the same attempt

  action             : Action
  receipt            : Receipt?           // what the executor claimed
  observed_effect    : ObservedEffect?    // what was independently observed
  objective_postcondition : Postcondition?// whether the objective was met

  persistent_id      : string?      // durable identifier of any created resource
  user_visible       : bool
  reason_persisted   : string?
  effect_class       : "REVERSIBLE"|"COMPENSATABLE"|"IRREVERSIBLE"|"UNKNOWN"

  evidence           : Evidence[]
  proof              : Proof?
  present_validity   : "VERIFIED"|"WORKING_ASSUMPTION"|"UNKNOWN"|"IN_DOUBT"
  recovery_state     : RecoveryState?

  observed_at_ms     : int          // unix ms
}
```

Persistence is never reduced to *create resource → resource exists*. That reduction is precisely
what this record shape forbids: `persistent_id` being populated says a resource exists; it says
nothing about `observed_effect` or `objective_postcondition`, which remain separately unfilled
until something actually looks.

## 3. Chain

```
record_body   = record without the record_id field
record_id     = "b1c1:" + B1_DIGEST(record_body)
prev_link(n)  = record_id(n-1)      for n > 0
prev_link(0)  = "b1c1:" + "0" * 64
```

`b1-ledger verify` walks the chain from seq 0 and recomputes every digest and link. Any mutation to
any field of any record breaks the record's own digest; any reordering, insertion, or deletion
breaks the link chain. Both are reported with the seq at which the chain first diverges.

This is tamper-**evident**, not tamper-proof: a party who can rewrite the whole file can rebuild a
consistent chain. It defends against the realistic threat — silent corruption, partial writes,
accidental edits, and a component quietly "fixing" history — not against an adversary with write
access and intent. Stating that limit is required by law L8; claiming cryptographic immutability
here would be exactly the kind of unearned certainty this system exists to prevent.

## 3a. Recording is not a separately authorized effect

Appending to the ledger is the **recording mechanism**, not an additional persistent effect
requiring its own authority envelope (`40-authority-gate.md`).

This has to be stated, because the alternative does not terminate: if writing the record were itself
a persistent effect, recording an action would require authorizing the recording, whose record would
require authorizing that recording, and so on. The same reasoning covers the compiled generation
package under `state/packages/` — local, derived, recomputable from the IR, and never leaving the
machine.

What the gate *is* consulted for is the effect that actually reaches outside: a provider call that
spends credits, a publication, a deployment, an external write. Under Route E that gate closes, and
its own words become the recorded reason generation did not happen — which is the point. A gate
consulted only where it always opens is decoration.

The carve-out is deliberately narrow. It covers append-only local audit state and derived planning
artifacts. It does not cover deletion, rewriting, or anything transmitted.

## 3b. Sealing belongs to the ledger, not to its callers

A component in another language supplies a record's *content* over IF-1; it does not supply the
record's position in history. `seq`, `prev_link` and `record_id` are assigned by the ledger.

A body arriving with any of those fields set is **rejected**, not silently overwritten. A caller
that picks its own sequence number or link is not recording an action, it is choosing where in the
chain to appear — and quietly correcting the field would hide that it was attempted. The refusal
names the field.

## 4. Storage

`state/ledger.jsonl`, one canonical record per line, append-only. JSON Lines because it is
append-friendly, greppable, recoverable after a partial write (a torn final line is detectable and
discardable without losing history), and readable by all fourteen languages with no dependency.

Each line is the record's B1-CANON-1 form, so the file's bytes are reproducible from the records
and a digest recomputation is a byte comparison.

### 4a. Appends are serialized

Reading the chain's tail and extending it is **one** operation. An appender **MUST** hold an
exclusive lock on the ledger across `next_seq` → `tail_link` → write, and **MUST** write a record in
a single call rather than emitting the line and its terminator separately.

Without this, two appenders read the same tail and both extend it. Measured, before the lock, with
24 concurrent `b1ledger append` processes — reproduced every time:

```
chain verification: CHAIN VERIFICATION FAILED: sequence gap: expected seq 1, found 0
  DUPLICATED: {0: 2, 2: 2, 7: 2, 9: 2, 12: 2, 15: 2, 18: 2, 20: 2}
  MISSING:    [1, 3, 8, 10, 13, 19, 21, 23]
```

`b1 plan` appends on every run, so two operators planning at once was enough to produce it.

What makes this a property of the chain rather than an implementation detail: **`verify` cannot tell
this damage from tampering.** A duplicated sequence number and a broken link are exactly what a
splice looks like. A tamper-evident log that manufactures its own alarms during ordinary use is
worse than one with no alarm, because it teaches its operator that the alarm means nothing — and it
does so precisely when the log is busiest, which is when tampering would be easiest to hide.

An appender that cannot take the lock within a bounded wait **MUST refuse**, and the caller **MUST**
be told the record was not written. Appending unserialized would assign a sequence number another
writer is already using; a refusal is a fact the caller can act on, and corruption is not.

The lock is advisory. It serializes every writer that takes it — every writer in this system — and
does not defend against a process that writes to the file directly. That is the honest boundary, and
it is the same one §3 already draws: the ledger offers evidence of damage, never prevention of it.

### 4b. An absent ledger is not an intact ledger

Verification distinguishes three states, and **MUST NOT** collapse the first two:

| State | Meaning | Verdict |
|---|---|---|
| The file does not exist | Nothing was checked | **Not** intact; a non-zero exit |
| The file exists and is empty | A correctly initialized ledger | Intact, 0 records |
| The file has records | The chain was walked | Intact, or the failure |

Treating a missing file as empty is right where the first append must create it, and catastrophic in
verification: `b1ledger verify` reported `chain intact: 0 record(s) verified` and exited 0 for a path
that did not exist, so a monitor pointed at a deleted ledger — or at a typo — was told the chain was
fine. Absence of evidence rendered as evidence of integrity is law L8 in its most compact form.

## 5. Outcome classification

```
classify(record):
  if action was never dispatched              -> NOT_EXECUTED
  if receipt is null                          -> IN_DOUBT
  if observed_effect is null                  -> IN_DOUBT      // receipt alone proves nothing
  if postcondition is null                    -> IN_DOUBT
  if postcondition.satisfied and no gate fail -> VERIFIED
  if postcondition partially satisfied        -> PARTIAL
  else                                        -> FAILED
```

Note the ordering: three separate paths into `IN_DOUBT` before `VERIFIED` becomes reachable. There
is deliberately no path from "receipt says ok" to `VERIFIED`.

## 6. P/E anomaly records

When state is discovered that no authorized action explains, an anomaly record is appended with
`origin` `P` or `E` (or `UNKNOWN` when even that cannot be attributed), `authorization_ref` null,
`present_validity` `IN_DOUBT`, and the evidence that led to its discovery.

An anomaly record is never rewritten into a normal record once explained. If provenance is later
established, a *new* record is appended referencing the anomaly as a causal parent. History is
append-only in meaning as well as in bytes — the point of L10 is that existence never becomes
retroactive authorization, and quietly editing the anomaly away would be exactly that.
