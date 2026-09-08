using System.Text;

namespace B1.Convergence;

/// <summary>
/// Entrypoint.
///
///   conform    read a JSON document on stdin, emit its B1-CANON-1 digest (SPEC/20 §5)
///   converge   read {baseline, candidate, attributed_to} on stdin, emit a gate outcome
///   selftest   run the regression gate's own checks
/// </summary>
public static class Program
{
    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var command = args.Length > 0 ? args[0] : "conform";

        return command switch
        {
            "conform" => Conform(),
            "converge" => Converge(),
            "selftest" => SelfTest.Run(),
            _ => Usage(),
        };
    }

    private static int Usage()
    {
        Console.Error.WriteLine("usage: B1.Convergence [conform|converge|selftest]");
        return 2;
    }

    private static string ReadStdin()
    {
        using var stdin = Console.OpenStandardInput();
        using var reader = new StreamReader(stdin, new UTF8Encoding(false), false);
        return reader.ReadToEnd();
    }

    private static int Conform()
    {
        var text = ReadStdin();
        try
        {
            Console.WriteLine(Canon.DigestText(text));
            return 0;
        }
        catch (B1Exception e)
        {
            Console.Error.WriteLine(e.Token);
            return 2;
        }
    }

    private static Dictionary<string, int?> ScoresFrom(Json? node)
    {
        var map = new Dictionary<string, int?>();
        if (node is Json.Obj obj)
        {
            foreach (var (k, v) in obj.Members)
            {
                map[k] = v switch
                {
                    Json.Int i => (int)i.Value,
                    _ => null, // null means not measured; it is not zero
                };
            }
        }
        return map;
    }

    private static int Converge()
    {
        var text = ReadStdin();
        try
        {
            if (Canon.Parse(text) is not Json.Obj root)
            {
                Console.Error.WriteLine("B1_ERR_PARSE");
                return 2;
            }

            var baseline = ScoresFrom(root.Get("baseline"));
            var candidate = ScoresFrom(root.Get("candidate"));
            var attributed = (root.Get("attributed_to") as Json.Str)?.Value;

            var dims = SystemDimensions.All
                .Where(d => baseline.ContainsKey(d.Name) || candidate.ContainsKey(d.Name))
                .ToList();
            if (dims.Count == 0) dims = SystemDimensions.All.ToList();

            var outcome = RegressionGate.Evaluate(baseline, candidate, dims, attributed);

            var deltas = outcome.Deltas.Select(d =>
            {
                var o = Json.NewObj();
                o.Members["name"] = new Json.Str(d.Name);
                o.Members["baseline"] = d.Baseline is null ? new Json.Null() : new Json.Int(d.Baseline.Value);
                o.Members["candidate"] = d.Candidate is null ? new Json.Null() : new Json.Int(d.Candidate.Value);
                o.Members["delta"] = d.Delta is null ? new Json.Null() : new Json.Int(d.Delta.Value);
                o.Members["verdict"] = new Json.Str(d.Verdict);
                return (Json)o;
            }).ToList();

            var result = Json.NewObj();
            result.Members["decision"] = new Json.Str(outcome.Retained ? "RETAIN" : "REJECT");
            result.Members["deltas"] = new Json.Arr(deltas);
            result.Members["reasons"] = new Json.Arr(
                outcome.Reasons.Select(r => (Json)new Json.Str(r)).ToList());
            result.Members["attributed_to"] = outcome.AttributedTo is null
                ? new Json.Null()
                : new Json.Str(outcome.AttributedTo);

            Console.WriteLine(Canon.Canonicalize(result));
            // 4 = a negative verdict, matching the authority gate and the quality engine. A
            // rejected candidate is the gate doing its job; conflating it with a malfunction would
            // make the two indistinguishable to any caller.
            return outcome.Retained ? 0 : 4;
        }
        catch (B1Exception e)
        {
            Console.Error.WriteLine(e.Token);
            return 2;
        }
    }
}
