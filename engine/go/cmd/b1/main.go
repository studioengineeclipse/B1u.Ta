// b1 — the operator CLI.
//
//	b1 discover           show the provider capability map and the selected route
//	b1 plan <ir.json>     run the closed loop as far as the authorized route permits
//	b1 status             show participation and ledger state
package main

import (
	"encoding/json"
	"fmt"
	"os"
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
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", os.Args[1])
		usage()
		code = 2
	}
	os.Exit(code)
}
