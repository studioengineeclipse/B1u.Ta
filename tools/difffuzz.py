#!/usr/bin/env python3
"""Differential fuzzer across the fourteen B1-CANON-1 implementations.

    python3 tools/difffuzz.py [seed] [document-count]
    rake fuzz[20260908,150]

The corpus proves the fourteen agree on the documents someone thought to write down. `rake
conform:coverage` proves the corpus contains a document for every category someone thought to name.
This asks the question neither can: **is there any document at all they disagree on?**

Generation is adversarial toward the profile's own rules — key syntax, integer range and form,
escape handling, surrogate pairs, depth, duplicate keys, insignificant whitespace — mixed with
byte-level mutation of the corpus, which is what produces documents no author would write.

Observation per implementation is `("ok", digest)` or `("err", token)`:

  * a split on the first component is a **correctness divergence** — one implementation accepts
    what another rejects, or two produce different digests for one document;
  * a split on the token alone is a diagnosis difference, and SPEC/20 §6 says precedence between
    tokens is unspecified, so these are reported and are not failures.

What this found on its first run, in code that had been green across 364 conformance checks since
pass 01: Ruby canonicalizing `true`/`false`/`null` as their offset in the input text; C#, Kotlin and
TypeScript accepting invalid UTF-8 and giving two different documents one digest; and — only after
those three were fixed — Swift rejecting every document containing a CRLF. Fourteen correctness
splits at seed 20260908, then zero.

The fixtures those defects deserved are now in the corpus, so `rake conform` catches a regression.
This stays because the next defect will be in a category nobody has named either.

Not part of `rake verify`: it is slow, and its result depends on the seed. Deterministic per seed,
so a reported divergence is reproducible — and passing one seed proves nothing about another, which
is the point of being able to run it with a different one.
"""

import json
import os
import random
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = str(Path(__file__).resolve().parent.parent)
TOKEN_RE = re.compile(r"^B1_ERR_[A-Z0-9_]+$")

ENV = dict(os.environ)
ENV["PATH"] += ":/opt/kotlinc/bin:/opt/swift/usr/bin:/opt/dart-sdk/bin"

LANGS = [(l["id"], l["conform"]) for l in
         json.load(open(f"{ROOT}/conformance/languages.json"))["languages"]]

KEY_CHARS = "ABCbcz09_$.-"
BAD_KEY_CHARS = " \t~!@#%^&*()+=[]{}|;:'\"<>,/?\\é中"


def rand_key(rng, legal=True):
    if legal:
        n = rng.choice([1, 1, 2, 3, 8, 64])
        return "".join(rng.choice(KEY_CHARS) for _ in range(n))
    kind = rng.randrange(5)
    if kind == 0:
        return ""
    if kind == 1:
        return "".join(rng.choice(KEY_CHARS) for _ in range(65))
    if kind == 2:
        return rng.choice(KEY_CHARS) + rng.choice(BAD_KEY_CHARS)
    if kind == 3:
        return rng.choice(BAD_KEY_CHARS)
    return "\\u0041"  # an escape in a key: is it decoded before the syntax check?


def rand_string(rng):
    """A JSON string literal, emitted as source text so escapes survive."""
    out = []
    for _ in range(rng.randrange(0, 6)):
        kind = rng.randrange(12)
        if kind == 0:
            out.append(rng.choice(['\\"', "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t"]))
        elif kind == 1:
            out.append("\\u%04x" % rng.randrange(0x20))          # control, must escape
        elif kind == 2:
            out.append("\\u%04X" % rng.randrange(0x20, 0x80))     # uppercase hex escape of ASCII
        elif kind == 3:
            out.append("\\ud83c\\udfa5")                          # valid surrogate pair
        elif kind == 4:
            out.append("\\u%04x" % rng.randrange(0xD800, 0xDC00))  # lone high
        elif kind == 5:
            out.append("\\u%04x" % rng.randrange(0xDC00, 0xE000))  # lone low
        elif kind == 6:
            out.append(rng.choice("ab é中\U0001f3ac  "))
        elif kind == 7:
            out.append("\\u0000")                                  # NUL via escape: legal JSON
        elif kind == 8:
            out.append("\\uFFFF")
        elif kind == 9:
            out.append("\\u00e9")                                  # escaped vs literal same char
        elif kind == 10:
            out.append("\\ufeff")
        else:
            out.append(rng.choice("XY01"))
    return '"' + "".join(out) + '"'


def rand_number(rng):
    kind = rng.randrange(10)
    if kind == 0:
        return "0"
    if kind == 1:
        return "-0"
    if kind == 2:
        return str(rng.randrange(-1000, 1000))
    if kind == 3:
        return str(9007199254740991)
    if kind == 4:
        return str(-9007199254740991)
    if kind == 5:
        return str(9007199254740992)
    if kind == 6:
        return str(rng.randrange(-10**18, 10**18))
    if kind == 7:
        return rng.choice(["1.0", "1.5", "-0.0", "0.0"])
    if kind == 8:
        return rng.choice(["1e3", "1E3", "1e+3", "1e-3", "0e0"])
    return rng.choice(["01", "+1", ".5", "5.", "1.", "-", "Infinity", "NaN", "0x10"])


def rand_value(rng, depth, maxdepth):
    if depth >= maxdepth:
        pick = rng.randrange(3)
    else:
        pick = rng.randrange(5)
    if pick == 0:
        return rng.choice(["true", "false", "null"])
    if pick == 1:
        return rand_number(rng)
    if pick == 2:
        return rand_string(rng)
    if pick == 3:
        n = rng.randrange(0, 4)
        return "[" + ",".join(rand_value(rng, depth + 1, maxdepth) for _ in range(n)) + "]"
    n = rng.randrange(0, 4)
    parts = []
    for _ in range(n):
        legal = rng.randrange(4) != 0
        parts.append(f'{json.dumps(rand_key(rng, legal))}:{rand_value(rng, depth + 1, maxdepth)}')
    if n and rng.randrange(6) == 0:            # duplicate a key
        parts.append(parts[rng.randrange(len(parts))])
    return "{" + ",".join(parts) + "}"


def ws(rng):
    return "".join(rng.choice([" ", "\t", "\n", "\r"]) for _ in range(rng.randrange(0, 3)))


def generate(rng):
    kind = rng.randrange(10)
    if kind == 9:                               # depth probe
        d = rng.choice([30, 31, 32, 33, 64, 65, 100])
        return ("[" * d) + "1" + ("]" * d)
    doc = rand_value(rng, 0, rng.choice([1, 2, 3, 6]))
    if rng.randrange(3) == 0:                   # legal insignificant whitespace
        doc = ws(rng) + doc + ws(rng)
    if rng.randrange(12) == 0:                  # trailing input
        doc = doc + rng.choice(["", " x", "}", "1", "\x00"])
    return doc


def mutate(rng, corpus):
    b = bytearray(rng.choice(corpus))
    for _ in range(rng.randrange(1, 4)):
        if not b:
            break
        op = rng.randrange(3)
        i = rng.randrange(len(b))
        if op == 0:
            b[i] = rng.randrange(256)
        elif op == 1:
            del b[i]
        else:
            b.insert(i, rng.randrange(256))
    return bytes(b)


def observe(cmd, doc):
    try:
        p = subprocess.run(cmd, shell=True, input=doc, capture_output=True,
                           timeout=60, cwd=ROOT, env=ENV)
    except subprocess.TimeoutExpired:
        return ("timeout", "")
    if p.returncode == 0:
        out = p.stdout.decode("utf-8", "replace").strip().splitlines()
        return ("ok", out[-1] if out else "<empty>")
    err = p.stderr.decode("utf-8", "replace").splitlines()
    tok = next((l.strip() for l in err if TOKEN_RE.match(l.strip())), None)
    if tok is None:
        return ("crash", f"rc={p.returncode} {(err[-1][:60] if err else '')}")
    return ("err", tok)


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 20260908
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    rng = random.Random(seed)

    corpus = []
    fixdir = f"{ROOT}/conformance/fixtures"
    for name in sorted(os.listdir(fixdir)):
        corpus.append(open(f"{fixdir}/{name}", "rb").read())

    docs = []
    for i in range(count):
        if i % 3 == 2:
            docs.append(mutate(rng, corpus))
        else:
            docs.append(generate(rng).encode("utf-8", "surrogatepass"))

    pool = ThreadPoolExecutor(max_workers=14)
    splits, token_splits, crashes = [], [], []

    for n, doc in enumerate(docs):
        results = dict(zip([lid for lid, _ in LANGS],
                           pool.map(lambda c: observe(c, doc), [c for _, c in LANGS])))
        outcomes = {lid: r for lid, r in results.items()}
        kinds = {r[0] for r in outcomes.values()}
        vals = {r for r in outcomes.values()}
        if "crash" in kinds or "timeout" in kinds:
            crashes.append((doc, outcomes))
        elif len(kinds) > 1 or ({"ok"} == kinds and len(vals) > 1):
            splits.append((doc, outcomes))
        elif len(vals) > 1:
            token_splits.append((doc, outcomes))
        if (n + 1) % 25 == 0:
            print(f"  {n+1}/{count}  splits={len(splits)} tokens={len(token_splits)} "
                  f"crashes={len(crashes)}", flush=True)

    def dump(title, items, limit=8):
        print(f"\n=== {title}: {len(items)} ===")
        for doc, out in items[:limit]:
            print(f"\ndoc ({len(doc)}B): {doc[:160]!r}")
            groups = {}
            for lid, r in out.items():
                groups.setdefault(r, []).append(lid)
            for r, ls in sorted(groups.items(), key=lambda kv: -len(kv[1])):
                print(f"   {r[0]:8} {str(r[1])[:64]:66} {','.join(sorted(ls))}")

    dump("CORRECTNESS SPLITS (accept/reject or digest disagreement)", splits)
    dump("CRASHES / TIMEOUTS", crashes)
    dump("TOKEN-ONLY SPLITS (all agree reject, disagree on why)", token_splits, 6)
    print(f"\nseed={seed} docs={count} splits={len(splits)} "
          f"token_splits={len(token_splits)} crashes={len(crashes)}")


if __name__ == "__main__":
    main()
