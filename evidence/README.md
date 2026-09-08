# Evidence stores

Two stores, deliberately separate (SPEC/70 §6):

| Path | Contents |
|---|---|
| `sora/` | Observations supplied by the user or project — prompt/result pairs, motion observations, continuity successes and failures, camera behaviours, occlusion handling, temporal artifacts, pacing, reference adherence, regeneration strategy, extension behaviour, shot grammar |
| `provider/` | Observations this system made itself, per provider and model |

## Both are empty, and that is the honest state

This system has never called a render provider. There are no observations because no observation has
been made. The stores are not seeded with plausible-looking example records: a fabricated
observation is indistinguishable from a real one once it is in the file, and the whole point of an
evidence store is that its contents were actually observed.

To add real evidence, append one canonical record per line to a `.jsonl` file in the appropriate
store. Browse with:

```sh
php -S 127.0.0.1:8081 surfaces/php/evidence.php
```

## Record shape

```json
{
  "record_id": "b1c1:<64 hex>",
  "source": "where this observation came from",
  "observation": "what was actually seen",
  "confidence_ppm": 750000,
  "conditions": "the conditions under which it was seen",
  "applicable_provider": "the provider it was observed on, or null",
  "transferability": "PROVIDER_SPECIFIC | CROSS_PROVIDER_OBSERVED | HYPOTHESIS_ONLY | UNKNOWN",
  "failure_cases": ["where this observation did not hold"],
  "recorded_at_ms": 0,
  "origin": "U | M | P | E | UNKNOWN"
}
```

`transferability` and `failure_cases` are not optional metadata. They exist so that the collapse
from "worked in Sora" to "will work in Seedance" requires writing a falsehood into the record rather
than merely omitting a caveat.

## The transfer law

```
SORA_EVIDENCE → hypothesis → provider experiment → observed result → provider-specific evidence
```

One-directional. A record observed on one provider, queried for another, comes back as
`HYPOTHESIS_ONLY` with its confidence stripped — enforced in `surfaces/php/evidence.php`
(`applicable_to`), not left to a reviewer to remember. The only thing that promotes a hypothesis to
a finding for a provider is an observed experiment on that provider.

Sora evidence is knowledge: prompting lessons, shot construction, continuity technique, failure
anticipation. It is not model weights, not a hidden API, not transferable neural capability, and not
proof that another model possesses Sora's behaviour.
