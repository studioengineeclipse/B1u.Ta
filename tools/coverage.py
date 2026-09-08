#!/usr/bin/env python3
"""Corpus completeness gate (SPEC/20 §7).

`rake conform` answers "do the fourteen implementations agree on these documents?" — a question
about the corpus. This answers the question about the *corpus itself*: does it contain a document
for every form and every rejection class the profile defines?

The distinction is not academic. Pass 03 found two CRITICAL defects that 364 green conformance
checks could not see:

  * Ruby's parser returned the offset where a literal ended instead of its value, so `{"a":true}`
    and `{"a":9}` shared a digest. No fixture contained `true`, `false` or `null`.
  * Three implementations decoded stdin lossily, so `{"a":"\\xff"}` and `{"a":"\\xfe"}` — different
    documents — shared a digest. No fixture contained a byte sequence that is not valid UTF-8.

Both were invisible for the same reason: nothing stated what the corpus was supposed to cover, so
nothing could report it missing. Fixing the four implementations leaves the corpus exactly as blind
to the next category nobody thinks of. This makes coverage a checked property instead of a habit.

What it cannot do is decide what is worth covering. `conformance/coverage.json` is a human judgement
about that, and it will be wrong again — the honest claim is "every category we have named is
present", never "every category exists".

    exit 0  every declared form and error class has a fixture, equivalences hold
    exit 4  a coverage gap — a negative verdict, not a malfunction
    exit 2  the corpus or its declaration could not be read
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "conformance" / "fixtures"
EXPECTED = ROOT / "conformance" / "expected.json"
DECLARED = ROOT / "conformance" / "coverage.json"


def forms_in(value: object) -> set[str]:
    """The B1-CANON-1 value forms present anywhere in a parsed document.

    `bool` is checked before `int` because Python makes `True` an instance of `int`, and collapsing
    them would report a corpus containing only integers as covering the literals — the exact blind
    spot this tool exists to close.
    """
    if value is None:
        return {"null"}
    if value is True:
        return {"true"}
    if value is False:
        return {"false"}
    if isinstance(value, str):
        return {"string"}
    if isinstance(value, int):
        return {"integer"}
    if isinstance(value, list):
        found = {"array"}
        for item in value:
            found |= forms_in(item)
        return found
    if isinstance(value, dict):
        found = {"object"}
        for item in value.values():
            found |= forms_in(item)
        return found
    return {f"UNEXPECTED:{type(value).__name__}"}


def main() -> int:
    try:
        declared = json.loads(DECLARED.read_text())
        expected = json.loads(EXPECTED.read_text())
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"cannot read the corpus declaration: {e}\n")
        return 2

    fixtures = expected.get("fixtures", {})
    gaps: list[str] = []

    # --- value forms ---------------------------------------------------------
    covered: dict[str, str] = {}
    for name, entry in sorted(fixtures.items()):
        if entry.get("negative"):
            continue
        path = FIXTURES / name
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
            # A positive fixture that will not parse is a corpus defect in its own right.
            gaps.append(f"positive fixture {name} is unreadable: {e}")
            continue
        for form in forms_in(doc):
            covered.setdefault(form, name)

    for form in declared["value_forms"]["required"]:
        if form not in covered:
            gaps.append(
                f"no positive fixture contains a {form}; agreement on that form is unverified"
            )

    # --- error classes -------------------------------------------------------
    errors: dict[str, str] = {}
    for name, entry in sorted(fixtures.items()):
        if entry.get("negative") and entry.get("error"):
            errors.setdefault(entry["error"], name)

    for token in declared["error_classes"]["required"]:
        if token not in errors:
            gaps.append(
                f"no negative fixture expects {token}; the rule it names may not be implemented"
            )

    # --- declared equivalences ----------------------------------------------
    for group in declared.get("equivalences", []):
        names = group.get("fixtures", [])
        if group.get("informational") or len(names) < 2:
            continue
        digests = {}
        for name in names:
            entry = fixtures.get(name)
            if entry is None:
                gaps.append(f"equivalence group names a missing fixture: {name}")
            elif entry.get("kind") != "digest":
                gaps.append(f"equivalence group names a negative fixture: {name}")
            else:
                digests[name] = entry["digest"]
        if len(set(digests.values())) > 1:
            gaps.append(
                "fixtures declared equivalent have different digests: "
                + ", ".join(f"{n}={d[:12]}" for n, d in sorted(digests.items()))
            )

    # --- report --------------------------------------------------------------
    print(f"corpus: {len(fixtures)} fixtures")
    print("  value forms:")
    for form in declared["value_forms"]["required"]:
        where = covered.get(form)
        print(f"    {form:9} {'covered by ' + where if where else 'MISSING'}")
    print("  error classes:")
    for token in declared["error_classes"]["required"]:
        where = errors.get(token)
        print(f"    {token:26} {'covered by ' + where if where else 'MISSING'}")
    for group in declared.get("equivalences", []):
        names = group.get("fixtures", [])
        if group.get("informational") or len(names) < 2:
            continue
        print(f"  equivalence: {', '.join(names)}")

    extra = sorted(set(covered) - set(declared["value_forms"]["required"]))
    if extra:
        print(f"  forms present but not declared required: {', '.join(extra)}")

    if gaps:
        print()
        for gap in gaps:
            print(f"  GAP: {gap}")
        print(f"\n{len(gaps)} coverage gap(s)")
        return 4

    print("\nevery declared form and error class has a fixture")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
