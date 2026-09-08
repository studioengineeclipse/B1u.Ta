namespace B1.Convergence;

/// <summary>
/// The convergence and regression gate. Normative: SPEC/50 §5, SPEC/00 L7.
/// </summary>
/// <remarks>
/// <para>The law it enforces:</para>
/// <code>
/// PREVIOUS_VERIFIED_BEST is the baseline.
/// A NEW_CANDIDATE must demonstrate improvement.
/// A REGRESSION is rejected.
/// </code>
/// <para>
/// "Scored higher on average" is explicitly not sufficient. That is the same averaging error the
/// hard gates exist to prevent, one level up: a candidate that gains four points across nineteen
/// dimensions and loses two hundred on identity has a better mean and is worse. Acceptance requires
/// a material improvement on at least one dimension, no material regression on any, and a change
/// the improvement can actually be attributed to.
/// </para>
/// <para>
/// A tie never replaces the baseline. Working behaviour is preserved unless an evidenced
/// improvement supersedes it, and "no worse" is not evidence of improvement.
/// </para>
/// </remarks>
public enum Direction
{
    /// <summary>Higher is better — the usual case for a quality dimension.</summary>
    HigherBetter,

    /// <summary>Lower is better — artifact severity, resource cost, unnecessary complexity.</summary>
    LowerBetter,
}

public sealed record Dimension(string Name, Direction Direction, int MaterialDelta);

/// <summary>
/// The eighteen regression dimensions of SPEC/00 L7 / §28, used when the system audits itself.
/// Candidate video segments are compared over the twenty-two quality dimensions instead; the gate
/// is the same, only the dimension set differs.
/// </summary>
public static class SystemDimensions
{
    public static readonly IReadOnlyList<Dimension> All = new[]
    {
        new Dimension("correctness", Direction.HigherBetter, 20),
        new Dimension("objective_alignment", Direction.HigherBetter, 20),
        new Dimension("clarity", Direction.HigherBetter, 30),
        new Dimension("determinism", Direction.HigherBetter, 20),
        new Dimension("authority_separation", Direction.HigherBetter, 10),
        new Dimension("epistemic_integrity", Direction.HigherBetter, 10),
        new Dimension("verification_strength", Direction.HigherBetter, 20),
        new Dimension("causal_traceability", Direction.HigherBetter, 20),
        new Dimension("recovery_capability", Direction.HigherBetter, 20),
        new Dimension("maintainability", Direction.HigherBetter, 30),
        new Dimension("dependency_integrity", Direction.HigherBetter, 20),
        new Dimension("polyglot_integrity", Direction.HigherBetter, 20),
        new Dimension("interface_integrity", Direction.HigherBetter, 20),
        new Dimension("output_completeness", Direction.HigherBetter, 20),
        new Dimension("unnecessary_complexity", Direction.LowerBetter, 30),
        new Dimension("working_behavior", Direction.HigherBetter, 10),
        new Dimension("resource_cost", Direction.LowerBetter, 50),
        new Dimension("execution_feasibility", Direction.HigherBetter, 20),
    };
}

public sealed record DimensionDelta(
    string Name,
    int? Baseline,
    int? Candidate,
    int? Delta,
    string Verdict); // IMPROVED | REGRESSED | UNCHANGED | UNMEASURED

public enum Decision
{
    Retain,
    Reject,
}

public sealed record GateOutcome(
    Decision Decision,
    IReadOnlyList<DimensionDelta> Deltas,
    IReadOnlyList<string> Reasons,
    string? AttributedTo)
{
    public bool Retained => Decision == Decision.Retain;
}

public static class RegressionGate
{
    /// <summary>
    /// Compares a candidate against the previous verified best.
    /// </summary>
    /// <param name="baseline">Scores for the current verified best.</param>
    /// <param name="candidate">Scores for the candidate.</param>
    /// <param name="dimensions">The dimension set and each one's material threshold.</param>
    /// <param name="attributedChange">
    /// The identified change the improvement is credited to. An improvement nobody can attribute to
    /// a change is not evidence that the change caused it, so the gate refuses to retain on it.
    /// </param>
    public static GateOutcome Evaluate(
        IReadOnlyDictionary<string, int?> baseline,
        IReadOnlyDictionary<string, int?> candidate,
        IReadOnlyList<Dimension> dimensions,
        string? attributedChange)
    {
        var deltas = new List<DimensionDelta>();
        var reasons = new List<string>();
        var improvements = new List<string>();
        var regressions = new List<string>();
        var newlyUnmeasured = new List<string>();

        foreach (var dim in dimensions)
        {
            baseline.TryGetValue(dim.Name, out var b);
            candidate.TryGetValue(dim.Name, out var c);

            if (b is null && c is null)
            {
                deltas.Add(new DimensionDelta(dim.Name, null, null, null, "UNMEASURED"));
                continue;
            }

            // Losing a measurement is a regression in verification strength, not a neutral change:
            // the candidate is less known than the baseline, and "we stopped checking" must never
            // read as "it got no worse".
            if (c is null)
            {
                deltas.Add(new DimensionDelta(dim.Name, b, null, null, "UNMEASURED"));
                newlyUnmeasured.Add(dim.Name);
                continue;
            }

            if (b is null)
            {
                deltas.Add(new DimensionDelta(dim.Name, null, c, null, "UNMEASURED"));
                continue;
            }

            var raw = c.Value - b.Value;
            var effective = dim.Direction == Direction.HigherBetter ? raw : -raw;

            string verdict;
            if (effective >= dim.MaterialDelta)
            {
                verdict = "IMPROVED";
                improvements.Add($"{dim.Name} {b}→{c}");
            }
            else if (effective <= -dim.MaterialDelta)
            {
                verdict = "REGRESSED";
                regressions.Add($"{dim.Name} {b}→{c}");
            }
            else
            {
                verdict = "UNCHANGED";
            }

            deltas.Add(new DimensionDelta(dim.Name, b, c, raw, verdict));
        }

        foreach (var name in newlyUnmeasured)
        {
            reasons.Add($"{name} was measured in the baseline and is not measured in the candidate; "
                        + "a lost measurement is a regression in verification strength, not a neutral change");
        }

        if (regressions.Count > 0)
        {
            reasons.Add($"material regression on {regressions.Count} dimension(s): {string.Join(", ", regressions)}");
        }

        if (improvements.Count == 0)
        {
            reasons.Add("no dimension improved materially; a tie does not replace the verified best, "
                        + "and preserving working behaviour is the default");
        }
        else
        {
            reasons.Add($"material improvement on {improvements.Count} dimension(s): {string.Join(", ", improvements)}");
        }

        if (string.IsNullOrWhiteSpace(attributedChange))
        {
            reasons.Add("the improvement is not attributed to an identified change, so it is not "
                        + "evidence that any change caused it");
        }

        var retain = improvements.Count > 0
                     && regressions.Count == 0
                     && newlyUnmeasured.Count == 0
                     && !string.IsNullOrWhiteSpace(attributedChange);

        return new GateOutcome(
            retain ? Decision.Retain : Decision.Reject,
            deltas,
            reasons,
            attributedChange);
    }

    /// <summary>
    /// Convergence status after an audit pass.
    /// </summary>
    /// <remarks>
    /// Iteration stopping is not convergence. A pass that ended because of a token, time, tool or
    /// access limit returns NOT_CONVERGED naming the limit — labelling that "converged" would claim
    /// a completeness the pass never established.
    /// </remarks>
    public static string ConvergenceStatus(
        int newMaterialDefects,
        int demonstratedImprovements,
        bool invariantsHold,
        string? stoppedByLimit)
    {
        if (!string.IsNullOrWhiteSpace(stoppedByLimit))
            return $"NOT_CONVERGED — stopped by a limit: {stoppedByLimit}";
        if (!invariantsHold)
            return "NOT_CONVERGED — a governing invariant is not satisfied";
        if (newMaterialDefects > 0)
            return $"NOT_CONVERGED — {newMaterialDefects} new material defect(s) found";
        if (demonstratedImprovements > 0)
            return $"NOT_CONVERGED — {demonstratedImprovements} improvement(s) still being demonstrated";
        return "CONVERGED_FOR_CURRENT_OBJECTIVE_AND_EVIDENCE";
    }
}
