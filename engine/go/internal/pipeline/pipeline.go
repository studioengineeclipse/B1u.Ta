// Package pipeline runs the closed loop (SPEC/00 L3, SPEC/70 §4).
//
//	intent -> IR -> discovery -> route -> compilation -> package
//	       -> [generation] -> ingestion -> analysis -> scoring -> verification
//
// Under Route E the loop legitimately stops after the package: there is no provider to call, so
// there is no receipt, no observed effect and no postcondition. The package says so explicitly
// rather than leaving a gap that reads like success.
package pipeline

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"b1/engine/internal/canon"
	"b1/engine/internal/discovery"
)

type Stage struct {
	Name   string
	Status string // RAN | SKIPPED | NOT_EXECUTED
	Detail string
}

type Result struct {
	IRDigest        string
	Route           discovery.Route
	RouteReason     string
	ExecutionStatus string // NOT_EXECUTED | EXECUTED
	Outcome         string // per SPEC/30 §5
	Stages          []Stage
	Package         canon.Value
	PackagePath     string
}

// CompilerCommand is the Java provider-neutral compiler, invoked over IF-1 (JSON on stdio).
// Go orchestrates; Java owns the compilation. Neither reimplements the other.
func CompilerCommand(root string) *exec.Cmd {
	return exec.Command("java", "-cp", filepath.Join(root, "engine/jvm/java/build"), "b1.compiler.Compile")
}

func compile(root string, irText string) (canon.Value, error) {
	cmd := CompilerCommand(root)
	cmd.Stdin = strings.NewReader(irText)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("compiler failed: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	return canon.Parse(string(out))
}

// Run executes the loop as far as the authorized route permits.
func Run(root, irPath, outDir string) (*Result, error) {
	irBytes, err := os.ReadFile(irPath)
	if err != nil {
		return nil, fmt.Errorf("cannot read IR: %w", err)
	}
	irText := string(irBytes)

	irValue, err := canon.Parse(irText)
	if err != nil {
		return nil, fmt.Errorf("IR is not a valid B1-CANON-1 document (%s)", canon.Token(err))
	}
	irDigest, err := canon.DigestValue(irValue)
	if err != nil {
		return nil, err
	}

	res := &Result{IRDigest: canon.B1C1(irDigest)}
	res.Stages = append(res.Stages, Stage{"ingest_ir", "RAN", "IR parsed and digested"})

	caps := discovery.Discover()
	route, reason := discovery.SelectRoute(caps)
	res.Route, res.RouteReason = route, reason
	res.Stages = append(res.Stages, Stage{"provider_discovery", "RAN",
		fmt.Sprintf("%d provider(s) probed; route %s", len(caps), route)})

	compiled, err := compile(root, irText)
	if err != nil {
		return nil, err
	}
	res.Stages = append(res.Stages, Stage{"compile", "RAN", "provider-neutral compilation completed"})

	// Everything past this point requires a provider. Under Route E there is none, and the loop
	// records that rather than synthesizing a plausible-looking receipt (law L8).
	planningOnly := route == discovery.RouteEPlanningOnly
	if planningOnly {
		res.ExecutionStatus = "NOT_EXECUTED"
		res.Outcome = "NOT_EXECUTED"
		for _, s := range []string{"generate", "ingest_media", "analyze", "score", "verify"} {
			res.Stages = append(res.Stages, Stage{s, "NOT_EXECUTED", "no authorized rendering provider"})
		}
	} else {
		// A provider call is a persistent effect and needs its own authority envelope; the
		// orchestrator does not spend credits because a route happens to be available.
		res.ExecutionStatus = "NOT_EXECUTED"
		res.Outcome = "NOT_EXECUTED"
		res.Stages = append(res.Stages, Stage{"generate", "NOT_EXECUTED",
			"route available but no effect-time authorization was presented for a credit-spending call"})
	}

	get := func(key string) canon.Value {
		if obj, ok := compiled.(*canon.Object); ok {
			if v, found := obj.Get(key); found {
				return v
			}
		}
		return canon.Null{}
	}

	pkg := canon.NewObject()
	pkg.Set("package_version", canon.String("b1-generation-package/1"))
	pkg.Set("ir_digest", canon.String(res.IRDigest))
	pkg.Set("route", canon.String(string(route)))
	pkg.Set("route_reason", canon.String(reason))
	pkg.Set("provider_id", canon.Null{})
	pkg.Set("model", canon.Null{})
	pkg.Set("compiled_prompt", get("compiled_prompt"))
	pkg.Set("negative_prompt", get("negative_prompt"))
	pkg.Set("reference_manifest", get("reference_manifest"))
	pkg.Set("provider_request", get("provider_request"))
	pkg.Set("continuation_state_digest", canon.Null{})
	pkg.Set("execution_status", canon.String(res.ExecutionStatus))
	pkg.Set("outcome", canon.String(res.Outcome))

	capsArr := canon.Array{}
	for _, c := range caps {
		capsArr = append(capsArr, c.Value())
	}
	pkg.Set("capability_map", capsArr)

	notes := canon.Array{
		canon.String("No media was generated. Every provider-facing field is a specification, not a result."),
		canon.String("Provider request shapes are CONTRACT_UNVERIFIED: no live provider contract has been observed."),
		canon.String("Quality vector and continuity state are absent because there is no output to measure."),
	}
	pkg.Set("notes", notes)
	pkg.Set("compiled_at_ms", canon.Int(time.Now().UnixMilli()))

	res.Package = pkg

	if outDir != "" {
		if err := os.MkdirAll(outDir, 0o755); err != nil {
			return nil, err
		}
		text, err := canon.Canonicalize(pkg)
		if err != nil {
			return nil, err
		}
		digest, err := canon.DigestValue(pkg)
		if err != nil {
			return nil, err
		}
		res.PackagePath = filepath.Join(outDir, "package-"+digest[:16]+".json")
		if err := os.WriteFile(res.PackagePath, []byte(text+"\n"), 0o644); err != nil {
			return nil, err
		}
	}

	return res, nil
}
