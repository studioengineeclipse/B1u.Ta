# Authority and Persistence Gate

Status: **NORMATIVE**. Implemented by `core/rust/b1-ledger` (`authority` module). This is the
mechanism behind law L4.

## 1. The distinction being enforced

```
PLAN_READY            — the action is fully specified and ready
EXECUTION_AUTHORIZED  — a specific user authorization is bound to this specific action
```

Analysis, reasoning, decomposition, inspection, planning, simulation, comparison, and preparation
proceed freely; they are not persistent effects and need no gate. What needs a gate is any lasting
state transition: creation, modification, deletion, rename, publication, deployment, transmission,
external write, durable memory change, resource persistence, configuration change, account change,
permission change, secret change, or any credit-spending provider call.

## 2. Authority envelope

Authorization binds to an envelope, never to a bare intention:

```
AuthorityEnvelope := {
  envelope_id           : string
  proposed_action       : Action
  target                : string        // what is acted upon
  scope                 : string[]      // bounds; what is NOT included is not authorized
  expected_effect       : string
  relevant_state_digest : string        // b1c1: digest of the state the plan assumed
  plan_digest           : string        // b1c1: digest of the plan
  causal_objective      : string
  effect_class          : "REVERSIBLE"|"COMPENSATABLE"|"IRREVERSIBLE"|"UNKNOWN"
  authorized_at_ms      : int
  authorized_by         : string
}

envelope_digest = B1_DIGEST(envelope without envelope_id and authorized_at_ms)
```

Authorization for one effect never silently authorizes another. An envelope authorizing "write
files under `/home/user/B1u.Ta` and push to branch X" does not authorize opening a pull request,
pushing to `main`, or calling a provider that spends credits — those are different targets and
different scopes, and each needs its own envelope.

## 3. Staleness

If any materially relevant part changes after authorization — action, target, scope, expected
effect, relevant state, plan, causal assumption, or execution condition — the authorization is
**stale** and the gate closes until it is refreshed.

Staleness is detected mechanically, not by good intentions:

```
check_at_effect_time(envelope, current_state, current_plan):
  recomputed = B1_DIGEST(envelope_body_with(current_state, current_plan))
  if recomputed != envelope.envelope_digest -> STALE   (gate closed)
  if now_ms > envelope.authorized_at_ms + max_age_ms -> EXPIRED (gate closed)
  otherwise -> OPEN
```

Because the envelope binds `relevant_state_digest` and `plan_digest`, any drift in the state the
plan assumed, or in the plan itself, changes the recomputed digest and closes the gate
automatically. This is the difference between an authority model and a promise: the system cannot
proceed on a stale authorization even if every component intends to behave.

## 4. Effect-time revalidation

The gate is checked **again immediately before the persistent transition**, not only at planning
time and not only at admission time. Planning-time approval is not permanent authorization;
admission-time approval is not effect-time authorization.

The result of that final check is recorded in the ledger record's `effect_time_validation` field,
so the record shows not merely that authorization existed, but that it was *still valid at the
moment the effect occurred*.

## 5. Effect classification — before authorization, not after

Every persistent action is classified before it is authorized:

| Class | Meaning |
|---|---|
| `REVERSIBLE` | The original state can reasonably be restored |
| `COMPENSATABLE` | Cannot be simply reversed, but a corrective action materially compensates |
| `IRREVERSIBLE` | Cannot reasonably be undone once applied |
| `UNKNOWN` | Recovery characteristics cannot currently be established |

Recovery limits are known *before* authorization rather than discovered afterwards. `UNKNOWN` is a
legitimate classification and is stated plainly; it is not quietly rounded down to `REVERSIBLE`
because the action looks harmless.

## 6. Execution identity

Three identities, never merged:

| Identity | Question it answers |
|---|---|
| Program identity | What logical component was supposed to act |
| Execution identity | Which concrete runtime, process, provider instance, or agent acted |
| Attempt identity | Which specific attempt produced this receipt or effect |

A retry is a new attempt, not the same one. A different executor may produce a materially different
effect. Merging these is how "we called it twice and it worked once" becomes an unanalysable
outcome.

## 7. Gate states

```
GateState := OPEN | CLOSED_UNAUTHORIZED | CLOSED_STALE | CLOSED_EXPIRED
           | CLOSED_SCOPE_VIOLATION | CLOSED_UNKNOWN_RECOVERY
```

`CLOSED_UNKNOWN_RECOVERY` applies where policy requires a known recovery path for the effect class
and none could be established. The gate defaults to closed: absence of a valid envelope is
`CLOSED_UNAUTHORIZED`, never an implicit open.
