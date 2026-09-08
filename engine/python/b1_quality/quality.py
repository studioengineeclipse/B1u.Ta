"""Quality vector, hard gates, and failure localization.

Normative: SPEC/50-quality-vector.md.

The central discipline here is that a mean is not a verdict. A candidate scoring well on twenty-one
dimensions and destroying character identity on the twenty-second is not a good candidate; it is a
failed one. Hard gates exist so that a catastrophic failure cannot hide behind a high average, and
an unmeasured dimension fails its gate rather than passing by default.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

DIMENSIONS: tuple[str, ...] = (
    "prompt_adherence_mu",
    "character_identity_mu",
    "temporal_identity_mu",
    "anatomy_mu",
    "motion_coherence_mu",
    "motion_complexity_mu",
    "physical_plausibility_mu",
    "interaction_correctness_mu",
    "camera_accuracy_mu",
    "spatial_consistency_mu",
    "depth_consistency_mu",
    "occlusion_consistency_mu",
    "lighting_consistency_mu",
    "material_consistency_mu",
    "environment_consistency_mu",
    "style_consistency_mu",
    "reference_adherence_mu",
    "narrative_progression_mu",
    "audio_alignment_mu",
    "continuity_start_mu",
    "continuity_end_mu",
    "artifact_severity_mu",
)

#: Higher is worse for these. Kept unnegated because that is what the analyzer measures — silently
#: flipping a sign inside a scoring pipeline is how thresholds end up backwards.
INVERTED: frozenset[str] = frozenset({"artifact_severity_mu"})

MEASUREMENT_BASES = ("MEASURED", "DECLARED", "INFERRED", "PROXY", "UNAVAILABLE")


@dataclass
class QualityVector:
    """Scores in milli-units, 0..1000.

    A dimension that could not be measured is ``None``, never ``0``. "We did not measure it" and
    "it scored zero" are different facts, and conflating them is the fastest way to manufacture a
    false verdict in either direction.
    """

    scores: dict[str, int | None] = field(default_factory=dict)
    basis: dict[str, str] = field(default_factory=dict)
    forbidden_event_count: int = 0

    def __post_init__(self) -> None:
        for d in DIMENSIONS:
            self.scores.setdefault(d, None)
            self.basis.setdefault(d, "UNAVAILABLE")
        unknown = set(self.scores) - set(DIMENSIONS)
        if unknown:
            raise ValueError(f"unknown quality dimensions: {sorted(unknown)}")
        for d, b in self.basis.items():
            if b not in MEASUREMENT_BASES:
                raise ValueError(f"{d}: measurement basis {b!r} is not one of {MEASUREMENT_BASES}")
        for d, v in self.scores.items():
            if v is not None and not (0 <= v <= 1000):
                raise ValueError(f"{d}: {v} is outside 0..1000 milli-units")

    def measured(self) -> dict[str, int]:
        return {d: v for d, v in self.scores.items() if v is not None}

    def unmeasured(self) -> list[str]:
        return sorted(d for d, v in self.scores.items() if v is None)

    def mean_mu(self) -> int | None:
        """The mean over measured dimensions.

        Provided for reporting only. It is deliberately never consulted by :func:`evaluate`: a
        candidate is accepted because it passed every gate, not because it averaged well.
        """
        m = self.measured()
        if not m:
            return None
        return sum(m.values()) // len(m)


@dataclass(frozen=True)
class HardGate:
    dimension: str
    comparator: str  # gte | lte | eq
    threshold_mu: int
    rationale: str

    def __post_init__(self) -> None:
        if self.comparator not in ("gte", "lte", "eq"):
            raise ValueError(f"unknown comparator {self.comparator!r}")
        if self.dimension not in DIMENSIONS and self.dimension != "forbidden_event_count":
            raise ValueError(f"unknown dimension {self.dimension!r}")


@dataclass(frozen=True)
class GateFailure:
    dimension: str
    comparator: str
    threshold_mu: int
    actual_mu: int | None
    reason: str  # BELOW_THRESHOLD | ABOVE_THRESHOLD | NOT_EQUAL | UNMEASURED
    margin_mu: int | None

    def describe(self) -> str:
        if self.reason == "UNMEASURED":
            return (
                f"{self.dimension}: required by a gate but never measured; "
                "an unmeasured dimension fails rather than passing by default"
            )
        return (
            f"{self.dimension}: {self.actual_mu} fails {self.comparator} {self.threshold_mu} "
            f"(short by {self.margin_mu})"
        )


@dataclass(frozen=True)
class GateResult:
    accepted: bool
    failures: tuple[GateFailure, ...]
    mean_mu: int | None

    def summary(self) -> str:
        if self.accepted:
            return f"ACCEPTED (all gates passed; mean of measured dimensions {self.mean_mu})"
        return f"REJECTED ({len(self.failures)} gate failure(s); mean {self.mean_mu} is not a verdict)"


def evaluate(vector: QualityVector, gates: Iterable[HardGate]) -> GateResult:
    """Applies hard gates.

    Acceptance requires every gate to pass and ``forbidden_event_count`` to be zero. The mean is
    computed for the report and plays no part in the decision.
    """
    failures: list[GateFailure] = []

    for gate in gates:
        if gate.dimension == "forbidden_event_count":
            actual = vector.forbidden_event_count
            ok = {
                "eq": actual == gate.threshold_mu,
                "lte": actual <= gate.threshold_mu,
                "gte": actual >= gate.threshold_mu,
            }[gate.comparator]
            if not ok:
                failures.append(
                    GateFailure(
                        gate.dimension, gate.comparator, gate.threshold_mu, actual,
                        "NOT_EQUAL" if gate.comparator == "eq" else "ABOVE_THRESHOLD",
                        abs(actual - gate.threshold_mu),
                    )
                )
            continue

        actual = vector.scores.get(gate.dimension)
        if actual is None:
            failures.append(
                GateFailure(gate.dimension, gate.comparator, gate.threshold_mu, None, "UNMEASURED", None)
            )
            continue

        if gate.comparator == "gte" and actual < gate.threshold_mu:
            failures.append(
                GateFailure(gate.dimension, "gte", gate.threshold_mu, actual,
                            "BELOW_THRESHOLD", gate.threshold_mu - actual)
            )
        elif gate.comparator == "lte" and actual > gate.threshold_mu:
            failures.append(
                GateFailure(gate.dimension, "lte", gate.threshold_mu, actual,
                            "ABOVE_THRESHOLD", actual - gate.threshold_mu)
            )
        elif gate.comparator == "eq" and actual != gate.threshold_mu:
            failures.append(
                GateFailure(gate.dimension, "eq", gate.threshold_mu, actual,
                            "NOT_EQUAL", abs(actual - gate.threshold_mu))
            )

    return GateResult(
        accepted=not failures,
        failures=tuple(failures),
        mean_mu=vector.mean_mu(),
    )


DEFAULT_GATES: tuple[HardGate, ...] = (
    HardGate("character_identity_mu", "gte", 700,
             "Identity drift is the failure a chained sequence most needs to prevent"),
    HardGate("continuity_start_mu", "gte", 750,
             "The first frame must be causally compatible with the previous terminal state"),
    HardGate("anatomy_mu", "gte", 650,
             "Anatomical breakdown is not compensated for by strength elsewhere"),
    HardGate("artifact_severity_mu", "lte", 250,
             "Artifacts compound across a chained sequence"),
    HardGate("forbidden_event_count", "eq", 0,
             "A negative constraint that fired is a specification violation, not a quality question"),
)


# --- failure localization -----------------------------------------------------

FAILURE_TYPES = (
    "IDENTITY_DRIFT", "ANATOMY_FAILURE", "MOTION_FAILURE", "PHYSICS_FAILURE", "CAMERA_FAILURE",
    "DEPTH_FAILURE", "OCCLUSION_FAILURE", "LIGHTING_FAILURE", "REFERENCE_FAILURE", "STYLE_FAILURE",
    "TEMPORAL_DISCONTINUITY", "OBJECT_PERSISTENCE_FAILURE", "ENVIRONMENT_DRIFT", "AUDIO_FAILURE",
    "NARRATIVE_FAILURE", "PROVIDER_LIMITATION", "UNKNOWN",
)

#: Which failure type a failing dimension points at. A dimension can implicate only one type here;
#: where evidence is genuinely ambiguous the result is UNKNOWN rather than a confident guess, because
#: a repair aimed at the wrong dimension costs a generation and teaches nothing.
_DIMENSION_TO_FAILURE = {
    "character_identity_mu": "IDENTITY_DRIFT",
    "temporal_identity_mu": "IDENTITY_DRIFT",
    "anatomy_mu": "ANATOMY_FAILURE",
    "motion_coherence_mu": "MOTION_FAILURE",
    "motion_complexity_mu": "MOTION_FAILURE",
    "physical_plausibility_mu": "PHYSICS_FAILURE",
    "interaction_correctness_mu": "PHYSICS_FAILURE",
    "camera_accuracy_mu": "CAMERA_FAILURE",
    "spatial_consistency_mu": "ENVIRONMENT_DRIFT",
    "depth_consistency_mu": "DEPTH_FAILURE",
    "occlusion_consistency_mu": "OCCLUSION_FAILURE",
    "lighting_consistency_mu": "LIGHTING_FAILURE",
    "material_consistency_mu": "STYLE_FAILURE",
    "environment_consistency_mu": "ENVIRONMENT_DRIFT",
    "style_consistency_mu": "STYLE_FAILURE",
    "reference_adherence_mu": "REFERENCE_FAILURE",
    "narrative_progression_mu": "NARRATIVE_FAILURE",
    "audio_alignment_mu": "AUDIO_FAILURE",
    "continuity_start_mu": "TEMPORAL_DISCONTINUITY",
    "continuity_end_mu": "TEMPORAL_DISCONTINUITY",
    "artifact_severity_mu": "UNKNOWN",
    "prompt_adherence_mu": "UNKNOWN",
}

_REPAIRS = {
    "IDENTITY_DRIFT": "Raise the weight of the CHARACTER_IDENTITY reference and restate the identity "
                      "anchor in the prompt. Do not rewrite sections that passed.",
    "ANATOMY_FAILURE": "Reduce motion complexity for the failing window and add an explicit anatomical "
                       "constraint; keep the rest of the prompt unchanged.",
    "MOTION_FAILURE": "Restate the motion as measured quantities over the failing window; the phase "
                      "at the window boundaries is what to make explicit.",
    "PHYSICS_FAILURE": "Add the violated physics expectation as an explicit observable constraint.",
    "CAMERA_FAILURE": "Restate the camera motion as a distance and a framing target rather than a "
                      "movement name.",
    "DEPTH_FAILURE": "Restate the depth layer ordering and require it to remain stable.",
    "OCCLUSION_FAILURE": "State the occluding element, the window it occludes over, and that the "
                         "subject persists behind it.",
    "LIGHTING_FAILURE": "State the key direction and that lighting holds unless a transition is given.",
    "REFERENCE_FAILURE": "Check the reference role bindings: a reference is influencing dimensions "
                         "outside its applies_to, or the one that should be binding is underweighted.",
    "STYLE_FAILURE": "Restate material behaviour observably rather than as a style adjective.",
    "TEMPORAL_DISCONTINUITY": "Bind the previous verified segment as the temporal reference and "
                              "restate the terminal state the first frame must continue from.",
    "ENVIRONMENT_DRIFT": "Bind the environment reference and restate the spatial layout.",
    "AUDIO_FAILURE": "State the audio phase at the segment boundary.",
    "NARRATIVE_FAILURE": "State the unresolved narrative items that must remain unresolved.",
    "PROVIDER_LIMITATION": "Route to an alternate provider: repair here means routing, not prompting.",
    "UNKNOWN": "Insufficient evidence to localize. Gather more measurement before regenerating; "
               "a repair aimed at a guessed dimension costs a generation and teaches nothing.",
}


@dataclass(frozen=True)
class FailureLocalization:
    failure_type: str
    failing_dimensions: tuple[str, ...]
    time_window_ms: tuple[int, int]
    evidence: tuple[str, ...]
    confidence_ppm: int
    suggested_repair: str


def localize(
    result: GateResult,
    vector: QualityVector,
    duration_ms: int,
    window_ms: tuple[int, int] | None = None,
) -> FailureLocalization | None:
    """Classifies a gate rejection before anything is regenerated.

    Repair targets only the failing dimensions. A prompt that succeeded is not rewritten from
    scratch because one dimension failed — that is what localization is for.
    """
    if result.accepted:
        return None

    failing = tuple(f.dimension for f in result.failures if f.dimension in DIMENSIONS)
    evidence = tuple(f.describe() for f in result.failures)

    if not failing:
        # Only forbidden_event_count fired: a specification violation, cleanly attributable.
        return FailureLocalization(
            "UNKNOWN", (), window_ms or (0, duration_ms), evidence, 1_000_000,
            "A negative constraint fired. Identify which forbidden event occurred and restate it; "
            "this is a specification violation rather than a quality shortfall.",
        )

    votes: dict[str, int] = {}
    for dim in failing:
        ftype = _DIMENSION_TO_FAILURE.get(dim, "UNKNOWN")
        votes[ftype] = votes.get(ftype, 0) + 1

    # An unmeasured dimension cannot support a confident classification: it is the absence of
    # evidence, not evidence of a particular failure.
    unmeasured_failures = sum(1 for f in result.failures if f.reason == "UNMEASURED")

    best_type, best_votes = max(votes.items(), key=lambda kv: kv[1])
    if best_type == "UNKNOWN" or unmeasured_failures == len(result.failures):
        confidence = 200_000
        best_type = "UNKNOWN"
    else:
        # Confidence falls as the failures spread across unrelated types: a single coherent
        # failure is a localization, several scattered ones are a symptom of something broader.
        confidence = min(950_000, 1_000_000 * best_votes // max(1, len(failing)))
        if unmeasured_failures:
            confidence = confidence * 2 // 3

    return FailureLocalization(
        failure_type=best_type,
        failing_dimensions=failing,
        time_window_ms=window_ms or (0, duration_ms),
        evidence=evidence,
        confidence_ppm=confidence,
        suggested_repair=_REPAIRS.get(best_type, _REPAIRS["UNKNOWN"]),
    )
