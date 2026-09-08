namespace B1.Convergence;

/// <summary>
/// Checks for the regression gate — success criterion S8: a candidate with no attributable
/// improvement is rejected and the verified best is preserved.
/// </summary>
internal static class SelfTest
{
    private static int _failures;

    private static void Check(string what, bool condition, string detail = "")
    {
        if (condition)
        {
            Console.WriteLine($"  ok    {what}");
        }
        else
        {
            Console.WriteLine($"  FAIL  {what}" + (detail.Length == 0 ? "" : $"\n        {detail}"));
            _failures++;
        }
    }

    private static Dictionary<string, int?> Scores(params (string, int?)[] pairs)
    {
        var baseScores = SystemDimensions.All.ToDictionary(d => d.Name, _ => (int?)500);
        foreach (var (k, v) in pairs) baseScores[k] = v;
        return baseScores;
    }

    public static int Run()
    {
        _failures = 0;
        var dims = SystemDimensions.All;

        Console.WriteLine("b1-canon-1 (c#)");
        Check("{} digest matches the published value",
            Canon.DigestText("{}") == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a");
        Check("member order and whitespace are irrelevant",
            Canon.DigestText("{\"b\":1,\"a\":2}") == Canon.DigestText("  { \"a\" : 2 , \"b\" : 1 }  "));
        Check("an escaped surrogate pair equals the literal character",
            Canon.DigestText("{\"x\":\"\\ud83c\\udfac\"}") == Canon.DigestText("{\"x\":\"\U0001F3AC\"}"));

        foreach (var (doc, token) in new[]
                 {
                     ("{\"a\":1.5}", "B1_ERR_NONINTEGER_NUMBER"),
                     ("{\"a\":9007199254740992}", "B1_ERR_NONINTEGER_NUMBER"),
                     ("{\"a b\":1}", "B1_ERR_KEY_SYNTAX"),
                     ("{\"a\":1,\"a\":2}", "B1_ERR_DUPLICATE_KEY"),
                     ("{\"a\":\"\\ud83c\"}", "B1_ERR_INVALID_UTF8"),
                 })
        {
            try
            {
                Canon.DigestText(doc);
                Check($"{doc} rejected", false, "it was accepted");
            }
            catch (B1Exception e)
            {
                Check($"{doc} rejected as {token}", e.Token == token, $"got {e.Token}");
            }
        }

        Console.WriteLine("regression gate");

        // A genuine, attributed improvement with no regression: retained.
        {
            var outcome = RegressionGate.Evaluate(
                Scores(), Scores(("clarity", 600)), dims, "replaced bin-wise L1 with EMD");
            Check("an attributed improvement with no regression is retained", outcome.Retained,
                string.Join("; ", outcome.Reasons));
        }

        // S8: no improvement at all. A tie must not replace the baseline.
        {
            var outcome = RegressionGate.Evaluate(Scores(), Scores(), dims, "some change");
            Check("an identical candidate is rejected", !outcome.Retained);
            Check("the reason is that nothing improved",
                outcome.Reasons.Any(r => r.Contains("no dimension improved materially")),
                string.Join("; ", outcome.Reasons));
        }

        // An improvement that nobody can attribute to a change.
        {
            var outcome = RegressionGate.Evaluate(Scores(), Scores(("clarity", 600)), dims, null);
            Check("an unattributed improvement is rejected", !outcome.Retained);
            Check("the reason names the missing attribution",
                outcome.Reasons.Any(r => r.Contains("not attributed")));
        }

        // The averaging trap: large gains, one material loss. Mean improves; the gate refuses.
        {
            var candidate = Scores(
                ("clarity", 900), ("maintainability", 900), ("determinism", 900),
                ("correctness", 400));
            var outcome = RegressionGate.Evaluate(Scores(), candidate, dims, "a broad refactor");
            Check("a candidate with a better mean but a material regression is rejected",
                !outcome.Retained,
                "gaining across three dimensions does not buy a loss on correctness");
            Check("the regression is named",
                outcome.Reasons.Any(r => r.Contains("material regression") && r.Contains("correctness")));
        }

        // A change below the material threshold is noise, not an improvement.
        {
            var outcome = RegressionGate.Evaluate(
                Scores(), Scores(("clarity", 510)), dims, "a small tweak");
            Check("a sub-threshold change counts as unchanged", !outcome.Retained,
                "clarity's material delta is 30; a 10-point move is noise");
        }

        // Lower-better dimensions are compared in the right direction.
        {
            var better = RegressionGate.Evaluate(
                Scores(), Scores(("unnecessary_complexity", 400)), dims, "removed a dead layer");
            Check("reducing unnecessary complexity is an improvement", better.Retained,
                string.Join("; ", better.Reasons));

            var worse = RegressionGate.Evaluate(
                Scores(), Scores(("clarity", 600), ("unnecessary_complexity", 600)), dims, "added a layer");
            Check("increasing unnecessary complexity is a regression", !worse.Retained);
        }

        // Losing a measurement is not a neutral change.
        {
            var candidate = Scores(("clarity", 600));
            candidate["verification_strength"] = null;
            var outcome = RegressionGate.Evaluate(Scores(), candidate, dims, "a refactor");
            Check("a candidate that stops measuring a dimension is rejected", !outcome.Retained);
            Check("the reason says a lost measurement is a regression",
                outcome.Reasons.Any(r => r.Contains("lost measurement")),
                string.Join("; ", outcome.Reasons));
        }

        Console.WriteLine("convergence status");
        Check("a clean audit converges",
            RegressionGate.ConvergenceStatus(0, 0, true, null) == "CONVERGED_FOR_CURRENT_OBJECTIVE_AND_EVIDENCE");
        Check("outstanding defects prevent convergence",
            RegressionGate.ConvergenceStatus(2, 0, true, null).StartsWith("NOT_CONVERGED"));
        Check("a broken invariant prevents convergence",
            RegressionGate.ConvergenceStatus(0, 0, false, null).StartsWith("NOT_CONVERGED"));
        Check("stopping for a limit is not convergence",
            RegressionGate.ConvergenceStatus(0, 0, true, "token budget").Contains("stopped by a limit"),
            "a pass that ran out of budget established nothing about completeness");

        Console.WriteLine();
        Console.WriteLine(_failures == 0 ? "PASSED: 0 failures" : $"FAILED: {_failures} failure(s)");
        return _failures == 0 ? 0 : 1;
    }
}
