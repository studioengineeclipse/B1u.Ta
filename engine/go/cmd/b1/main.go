// b1 — the operator CLI.
//
//	b1 discover           show the provider capability map and the selected route
//	b1 plan <ir.json>     run the closed loop as far as the authorized route permits
//	b1 status             show participation and ledger state
//	b1 score <vec.json>   apply hard gates and localize failure (Python)
//	b1 continuity <b.json> check causal compatibility across a segment boundary (Kotlin)
//	b1 converge <c.json>  compare a candidate against the verified best (C#)
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"b1/engine/internal/discovery"
	"b1/engine/internal/pipeline"
)

func repoRoot() string {
	if r := os.Getenv("B1_ROOT"); r != "" {
		return r
	}
	dir, err := os.Getwd()
	if err != nil {
		return "."
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "SPEC", "00-governing-laws.md")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "."
		}
		dir = parent
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, strings.TrimSpace(`
b1 — B1μ-DQAS Ω13.9 orchestrator

  b1 discover           show the provider capability map and the selected route
  b1 plan <ir.json>     run the closed loop as far as the authorized route permits
  b1 status             show participation and ledger state

  b1 score <vector.json>     apply hard gates and localize failure
  b1 continuity <bound.json> check causal compatibility across a segment boundary
  b1 converge <cmp.json>     compare a candidate against the previous verified best
`))
}

func cmdDiscover() int {
	caps := discovery.Discover()
	route, reason := discovery.SelectRoute(caps)

	fmt.Printf("%-20s %-22s %-12s %-14s %s\n", "provider", "route", "credential", "entitlement", "contract")
	fmt.Println(strings.Repeat("-", 92))
	for _, c := range caps {
		cred := "absent"
		if c.CredentialPresent {
			cred = "present"
		}
		fmt.Printf("%-20s %-22s %-12s %-14s %s\n",
			c.ProviderID, c.Route, cred, c.EntitlementObserved, c.ContractStatus)
	}

	if names := discovery.PresentCredentialNames(); len(names) > 0 {
		// Names only. A discovery tool that printed values would be the leak it exists to avoid.
		fmt.Printf("\ncredentials found (names only): %s\n", strings.Join(names, ", "))
	} else {
		fmt.Printf("\ncredentials found: none\n")
	}

	fmt.Printf("\nselected route: %s\n", route)
	fmt.Printf("reason: %s\n", reason)
	if route == discovery.RouteEPlanningOnly {
		fmt.Println("\nPLANNING_ONLY: complete generation packages will be produced and stamped")
		fmt.Println("EXECUTION_STATUS=NOT_EXECUTED. No media will be generated and none will be implied.")
	}
	return 0
}

func cmdPlan(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: b1 plan <ir.json>")
		return 2
	}
	root := repoRoot()
	res, err := pipeline.Run(root, args[0], filepath.Join(root, "state", "packages"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "plan failed: %v\n", err)
		return 1
	}

	fmt.Printf("IR digest    : %s\n", res.IRDigest)
	fmt.Printf("route        : %s\n", res.Route)
	fmt.Printf("reason       : %s\n\n", res.RouteReason)

	fmt.Printf("%-20s %-14s %s\n", "stage", "status", "detail")
	fmt.Println(strings.Repeat("-", 92))
	for _, s := range res.Stages {
		fmt.Printf("%-20s %-14s %s\n", s.Name, s.Status, s.Detail)
	}

	fmt.Printf("\nEXECUTION_STATUS = %s\n", res.ExecutionStatus)
	fmt.Printf("OUTCOME          = %s\n", res.Outcome)
	if res.PackagePath != "" {
		rel, _ := filepath.Rel(root, res.PackagePath)
		fmt.Printf("package          = %s\n", rel)
	}
	return 0
}

func cmdStatus() int {
	root := repoRoot()

	path := filepath.Join(root, "state", "participation.json")
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Println("participation: not probed yet (run `rake probe`)")
	} else {
		var doc struct {
			Languages []struct {
				Name        string `json:"name"`
				Status      string `json:"status"`
				StatusBasis string `json:"status_basis"`
			} `json:"languages"`
		}
		if err := json.Unmarshal(data, &doc); err == nil {
			integrating := 0
			for _, l := range doc.Languages {
				if l.Status == "INTEGRATES" || l.Status == "EFFECT_VERIFIED" || l.Status == "POSTCONDITION_VERIFIED" {
					integrating++
				}
			}
			fmt.Printf("participation: %d/14 at INTEGRATES or above\n", integrating)
			for _, l := range doc.Languages {
				fmt.Printf("  %-12s %s\n", l.Name, l.Status)
			}
		}
	}

	ledger := filepath.Join(root, "state", "ledger.jsonl")
	if info, err := os.Stat(ledger); err == nil {
		lines, _ := os.ReadFile(ledger)
		n := 0
		for _, l := range strings.Split(string(lines), "\n") {
			if strings.TrimSpace(l) != "" {
				n++
			}
		}
		fmt.Printf("\nledger: %d record(s), %d bytes (verify with `b1ledger verify`)\n", n, info.Size())
	} else {
		fmt.Printf("\nledger: empty\n")
	}
	return 0
}

// component routes an operator command to the language that owns that responsibility, over IF-1.
//
// Go does not reimplement any of them. Before these existed the three engines were reachable only
// from their own test suites, which meant an operator could not exercise the gate policy, the
// continuity predicates or the regression rule against their own input at all.
//
// A non-zero exit from the component is not necessarily a malfunction: a rejected candidate and a
// failed compatibility check are verdicts. Their output is passed through and the exit code
// preserved so the caller can tell a verdict from a breakage.
func component(name string, args []string, path string) int {
	if path == "" {
		fmt.Fprintf(os.Stderr, "usage: b1 %s <input.json>\n", name)
		return 2
	}
	if _, err := os.Stat(path); err != nil {
		fmt.Fprintf(os.Stderr, "cannot read %s: %v\n", path, err)
		return 2
	}

	input, err := os.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot open %s: %v\n", path, err)
		return 2
	}
	defer input.Close()

	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin = input
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			return exit.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "%s is not built or not runnable: %v\n", name, err)
		return 3
	}
	return 0
}

func arg(args []string, i int) string {
	if len(args) > i {
		return args[i]
	}
	return ""
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var code int
	switch os.Args[1] {
	case "discover":
		code = cmdDiscover()
	case "plan":
		code = cmdPlan(os.Args[2:])
	case "status":
		code = cmdStatus()
	case "score":
		root := repoRoot()
		code = component("score",
			[]string{"python3", filepath.Join(root, "engine/python/b1_quality/cli.py")},
			arg(os.Args[2:], 0))
	case "continuity":
		root := repoRoot()
		code = component("continuity",
			[]string{"java", "-cp",
				filepath.Join(root, "engine/jvm/kotlin/build/b1continuity.jar") + ":" +
					filepath.Join(root, "engine/jvm/java/build"),
				"b1.continuity.MainKt", "compatibility"},
			arg(os.Args[2:], 0))
	case "converge":
		root := repoRoot()
		code = component("converge",
			[]string{"dotnet",
				filepath.Join(root, "engine/csharp/B1.Convergence/bin/Release/net8.0/B1.Convergence.dll"),
				"converge"},
			arg(os.Args[2:], 0))
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", os.Args[1])
		usage()
		code = 2
	}
	os.Exit(code)
}
