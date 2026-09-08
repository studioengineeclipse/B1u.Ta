"""Tests for the quality vector, hard gates and failure localization.

Establishes success criterion S5: a catastrophic failure in one dimension is rejected however good
the average is. That property is easy to state and easy to lose, because averaging is the default
behaviour of almost every scoring system.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from b1_quality.canon import B1Error, digest_text  # noqa: E402
from b1_quality.quality import (  # noqa: E402
    DEFAULT_GATES,
    DIMENSIONS,
    HardGate,
    QualityVector,
    evaluate,
    localize,
)


def strong(**overrides):
    """A vector scoring 900 everywhere, 50 artifact severity, with the given overrides applied."""
    scores = {d: 900 for d in DIMENSIONS}
    scores["artifact_severity_mu"] = 50
    scores.update(overrides)
    return QualityVector(
        scores=scores,
        basis={d: "MEASURED" for d in DIMENSIONS},
    )


class TestHardGates(unittest.TestCase):
    def test_strong_candidate_is_accepted(self):
        result = evaluate(strong(), DEFAULT_GATES)
        self.assertTrue(result.accepted, result.summary())

    def test_s5_one_catastrophic_dimension_rejects_despite_high_mean(self):
        # Twenty-one dimensions at 900, character identity destroyed.
        vector = strong(character_identity_mu=0)
        result = evaluate(vector, DEFAULT_GATES)

        self.assertFalse(result.accepted, "a destroyed identity must not pass on a good average")
        self.assertGreater(result.mean_mu, 800, "the mean really is high — that is the point")
        self.assertEqual([f.dimension for f in result.failures], ["character_identity_mu"])
        self.assertEqual(result.failures[0].margin_mu, 700)

    def test_rejection_names_the_gate_and_the_margin(self):
        result = evaluate(strong(continuity_start_mu=600), DEFAULT_GATES)
        self.assertFalse(result.accepted)
        failure = result.failures[0]
        self.assertEqual(failure.dimension, "continuity_start_mu")
        self.assertEqual(failure.actual_mu, 600)
        self.assertEqual(failure.margin_mu, 150)
        self.assertIn("short by 150", failure.describe())

    def test_unmeasured_dimension_fails_its_gate(self):
        vector = strong()
        vector.scores["character_identity_mu"] = None
        vector.basis["character_identity_mu"] = "UNAVAILABLE"

        result = evaluate(vector, DEFAULT_GATES)
        self.assertFalse(result.accepted, "absence of evidence must not read as evidence of adequacy")
        self.assertEqual(result.failures[0].reason, "UNMEASURED")

    def test_inverted_dimension_uses_lte(self):
        self.assertTrue(evaluate(strong(artifact_severity_mu=250), DEFAULT_GATES).accepted)
        self.assertFalse(evaluate(strong(artifact_severity_mu=251), DEFAULT_GATES).accepted)

    def test_forbidden_event_rejects_outright(self):
        vector = strong()
        vector.forbidden_event_count = 1
        result = evaluate(vector, DEFAULT_GATES)
        self.assertFalse(result.accepted)
        self.assertEqual(result.failures[0].dimension, "forbidden_event_count")

    def test_mean_is_reported_but_never_decides(self):
        # A candidate whose mean is poor but which passes every gate is accepted: the gates are the
        # verdict in both directions, not just the rejecting one.
        scores = {d: 400 for d in DIMENSIONS}
        scores.update(
            character_identity_mu=700,
            continuity_start_mu=750,
            anatomy_mu=650,
            artifact_severity_mu=250,
        )
        vector = QualityVector(scores=scores, basis={d: "MEASURED" for d in DIMENSIONS})
        result = evaluate(vector, DEFAULT_GATES)
        self.assertTrue(result.accepted)
        self.assertLess(result.mean_mu, 500)

    def test_unknown_dimension_is_rejected_at_construction(self):
        with self.assertRaises(ValueError):
            QualityVector(scores={"not_a_dimension_mu": 500})

    def test_score_outside_range_is_rejected(self):
        with self.assertRaises(ValueError):
            QualityVector(scores={"anatomy_mu": 1001})

    def test_gate_on_unknown_dimension_is_rejected(self):
        with self.assertRaises(ValueError):
            HardGate("nonexistent_mu", "gte", 500, "typo")


class TestFailureLocalization(unittest.TestCase):
    def test_accepted_result_has_no_localization(self):
        self.assertIsNone(localize(evaluate(strong(), DEFAULT_GATES), strong(), 5000))

    def test_identity_failure_localizes_to_identity_drift(self):
        vector = strong(character_identity_mu=100)
        loc = localize(evaluate(vector, DEFAULT_GATES), vector, 5000)
        self.assertEqual(loc.failure_type, "IDENTITY_DRIFT")
        self.assertEqual(loc.failing_dimensions, ("character_identity_mu",))
        self.assertIn("CHARACTER_IDENTITY reference", loc.suggested_repair)
        self.assertIn("Do not rewrite sections that passed", loc.suggested_repair)

    def test_continuity_failure_localizes_to_temporal_discontinuity(self):
        vector = strong(continuity_start_mu=100)
        loc = localize(evaluate(vector, DEFAULT_GATES), vector, 5000)
        self.assertEqual(loc.failure_type, "TEMPORAL_DISCONTINUITY")
        self.assertIn("previous verified segment", loc.suggested_repair)

    def test_unmeasured_failures_reduce_confidence(self):
        measured = strong(character_identity_mu=100)
        confident = localize(evaluate(measured, DEFAULT_GATES), measured, 5000)

        unmeasured = strong()
        unmeasured.scores["character_identity_mu"] = None
        vague = localize(evaluate(unmeasured, DEFAULT_GATES), unmeasured, 5000)

        self.assertLess(
            vague.confidence_ppm,
            confident.confidence_ppm,
            "an unmeasured dimension is the absence of evidence, not evidence of a failure type",
        )

    def test_scattered_failures_reduce_confidence(self):
        focused = strong(character_identity_mu=100)
        focused_loc = localize(evaluate(focused, DEFAULT_GATES), focused, 5000)

        gates = DEFAULT_GATES + (
            HardGate("camera_accuracy_mu", "gte", 700, "test"),
            HardGate("lighting_consistency_mu", "gte", 700, "test"),
        )
        scattered = strong(character_identity_mu=100, camera_accuracy_mu=100, lighting_consistency_mu=100)
        scattered_loc = localize(evaluate(scattered, gates), scattered, 5000)

        self.assertLess(
            scattered_loc.confidence_ppm,
            focused_loc.confidence_ppm,
            "failures spread across unrelated types indicate something broader than one dimension",
        )


class TestCanonAgreement(unittest.TestCase):
    """The Python canon must agree with the values every other language reproduces."""

    def test_known_digests(self):
        self.assertEqual(
            digest_text("{}"),
            "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
        )
        self.assertEqual(digest_text('{"b":1,"a":2}'), digest_text('  { "a" : 2 , "b" : 1 }  '))
        self.assertEqual(digest_text(r'{"x":"🎬"}'), digest_text('{"x":"\U0001F3AC"}'))

    def test_rejections(self):
        for doc, token in [
            ('{"a":1.5}', "B1_ERR_NONINTEGER_NUMBER"),
            ('{"a":9007199254740992}', "B1_ERR_NONINTEGER_NUMBER"),
            ('{"a b":1}', "B1_ERR_KEY_SYNTAX"),
            ('{"a":1,"a":2}', "B1_ERR_DUPLICATE_KEY"),
            (r'{"a":"\ud83c"}', "B1_ERR_INVALID_UTF8"),
        ]:
            with self.assertRaises(B1Error) as ctx:
                digest_text(doc)
            self.assertEqual(ctx.exception.token, token, doc)


if __name__ == "__main__":
    unittest.main(verbosity=2)
