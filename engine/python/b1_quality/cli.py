"""Operator entrypoint for the quality engine.

    stdin/argv : a quality vector document
    stdout     : gate result and, on rejection, a failure localization

Before this existed the quality engine was reachable only from its own test suite. That is a real
gap — a component nobody can run is a component nobody can check — but closing it introduces a risk
worth naming.

A hand-authored quality vector contains *declared* numbers. If a verdict over declared input were
rendered identically to a verdict over measured input, this command would become a way to
manufacture a quality result from nothing: type in twenty-two numbers, receive an ACCEPTED. That is
precisely the failure SPEC/50 §6 exists to prevent, arriving through the front door.

So two rules apply here that do not apply to the library:

  * `measurement_basis` is **required**. A vector that omits it is refused rather than defaulting to
    MEASURED — silence must not be read as "measured".
  * A verdict resting on DECLARED or INFERRED input is rendered, clearly labelled, and marked
    **ineligible to become a verified best**. Useful for trying gate policy against hypothetical
    scores; not usable as evidence about any actual output.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from b1_quality.canon import B1Error, canonicalize  # noqa: E402
from b1_quality.quality import (  # noqa: E402
    DEFAULT_GATES,
    DIMENSIONS,
    HardGate,
    QualityVector,
    evaluate,
    localize,
)

#: Bases that describe an actual observation of real output.
EVIDENTIAL = {"MEASURED", "PROXY"}


class InputError(Exception):
    """The supplied document cannot be scored as given."""


def load_vector(doc: dict) -> tuple[QualityVector, dict[str, str]]:
    scores_in = doc.get("scores")
    if not isinstance(scores_in, dict):
        raise InputError("the document must carry a `scores` object")

    basis_in = doc.get("measurement_basis")
    if not isinstance(basis_in, dict):
        raise InputError(
            "the document must carry a `measurement_basis` object naming how each score was "
            "obtained. It is required rather than defaulted because defaulting to MEASURED would "
            "let silence pass as evidence."
        )

    scores: dict[str, int | None] = {}
    for dim, value in scores_in.items():
        if dim not in DIMENSIONS:
            raise InputError(f"unknown dimension {dim!r}")
        if value is not None and not isinstance(value, int):
            raise InputError(f"{dim}: scores are integers in milli-units, or null if unmeasured")
        scores[dim] = value

    missing_basis = sorted(d for d, v in scores.items() if v is not None and d not in basis_in)
    if missing_basis:
        raise InputError(
            "every scored dimension needs a measurement_basis; missing for: "
            + ", ".join(missing_basis)
        )

    vector = QualityVector(
        scores=scores,
        basis={d: basis_in.get(d, "UNAVAILABLE") for d in DIMENSIONS},
        forbidden_event_count=int(doc.get("forbidden_event_count", 0)),
    )
    return vector, basis_in


def load_gates(doc: dict) -> tuple[HardGate, ...]:
    raw = doc.get("gates")
    if raw is None:
        return DEFAULT_GATES
    return tuple(
        HardGate(g["dimension"], g["comparator"], int(g["threshold_mu"]), g.get("rationale", ""))
        for g in raw
    )


def score(doc: dict) -> dict:
    vector, basis = load_vector(doc)
    gates = load_gates(doc)
    result = evaluate(vector, gates)

    scored = {d: b for d, b in basis.items() if vector.scores.get(d) is not None}
    declared = sorted(d for d, b in scored.items() if b not in EVIDENTIAL)
    evidential = bool(scored) and not declared

    out: dict = {
        "accepted": result.accepted,
        "mean_mu": result.mean_mu,
        "summary": result.summary(),
        "failures": [
            {
                "dimension": f.dimension,
                "comparator": f.comparator,
                "threshold_mu": f.threshold_mu,
                "actual_mu": f.actual_mu,
                "reason": f.reason,
                "margin_mu": f.margin_mu,
                "detail": f.describe(),
            }
            for f in result.failures
        ],
        "rests_on_evidence": evidential,
        "eligible_as_verified_best": evidential,
    }

    if not evidential:
        out["declared_dimensions"] = declared
        out["caveat"] = (
            "This verdict rests on declared or inferred input, not on measured output. It is "
            "useful for exercising gate policy and is not evidence about any generated media; it "
            "cannot become a verified best."
        )

    localization = localize(result, vector, int(doc.get("duration_ms", 0)))
    if localization is not None:
        out["localization"] = {
            "failure_type": localization.failure_type,
            "failing_dimensions": list(localization.failing_dimensions),
            "time_window_ms": {
                "start": localization.time_window_ms[0],
                "end": localization.time_window_ms[1],
            },
            "evidence": list(localization.evidence),
            "confidence_ppm": localization.confidence_ppm,
            "suggested_repair": localization.suggested_repair,
        }

    return out


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        text = Path(argv[1]).read_text()
    else:
        text = sys.stdin.read()

    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"input is not valid JSON: {e}\n")
        return 2

    try:
        result = score(doc)
    except InputError as e:
        sys.stderr.write(f"refused: {e}\n")
        return 2
    except (ValueError, KeyError, TypeError) as e:
        sys.stderr.write(f"refused: {e}\n")
        return 2

    try:
        sys.stdout.write(canonicalize(result) + "\n")
    except B1Error as e:
        sys.stderr.write(f"{e.token}\n")
        return 2

    # A rejected candidate is a verdict, not a malfunction; exit 4 distinguishes the two.
    return 0 if result["accepted"] else 4


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
