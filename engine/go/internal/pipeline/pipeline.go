// Package pipeline runs the closed loop (SPEC/00 L3, SPEC/70 §4).
//
//	intent -> IR -> references -> discovery -> route -> compilation -> gate
//	       -> [generation] -> ingestion -> analysis -> scoring -> verification
//	       -> ledger
//
// Under Route E the loop legitimately stops after compilation: there is no provider to call, so
// there is no receipt, no observed effect and no postcondition. The package says so explicitly
// rather than leaving a gap that reads like success.
//
// Two boundaries are worth being precise about, because getting them wrong in either direction
// makes the authority model theatre:
//
//   - Writing the package and appending the ledger record are *local derived state*. Both are
//     recomputable from the IR, neither leaves this machine, and the ledger append is the recording
//     mechanism itself — gating it would mean authorizing the recording of an action before
//     recording it, which does not terminate. Neither requires an envelope.
//   - Calling a provider is a persistent external effect that spends credits. That is what the gate
//     is consulted for, and under Route E it closes. The gate's own words then become the recorded
//     reason generation did not happen, rather than a formality nobody reads.
package pipeline

import (
	"encoding/json"
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
	Status string // RAN | SKIPPED | NOT_EXECUTED | REFUSED
	Detail string
}

type Result struct {
	IRDigest        string
	Route           discovery.Route
	RouteReason     string
	ExecutionStatus string // NOT_EXECUTED | EXECUTED
	Outcome         string // per SPEC/30 §5
	GateState       string
	GateDetail      string
	Stages          []Stage
	Package         canon.Value
	PackagePath     string
	RecordID        string
}

func root(path string, parts ...string) string {
	return filepath.Join(append([]string{path}, parts...)...)
}

// run executes a component over IF-1 and returns stdout. A non-zero exit whose code appears in
// `tolerate` is returned with its output rather than as an error: a closed gate is a verdict, not
// a malfunction, and conflating the two would make a refusal look like a broken component.
func run(cmd *exec.Cmd, stdin string, tolerate ...int) (string, error) {
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			for _, code := range tolerate {
				if exit.ExitCode() == code {
					return string(out), nil
				}
			}
		}
		return string(out), fmt.Errorf("%v: %s", err, strings.TrimSpace(stderr.String()))
	}
	return string(out), nil
}

// --- reference role check (Swift, IF-1) ---------------------------------------

type referenceFinding struct {
	Kind         string   `json:"kind"`
	ReferenceIDs []string `json:"reference_ids"`
	Path         *string  `json:"path"`
	Detail       string   `json:"detail"`
}

type referenceResult struct {
	Admissible      bool               `json:"admissible"`
	BindingsChecked int                `json:"bindings_checked"`
	Findings        []referenceFinding `json:"findings"`
}

func checkReferences(repo, irText string) (*referenceResult, error) {
	bin := root(repo, "engine", "swift", "build", "b1reference")
	if _, err := os.Stat(bin); err != nil {
		return nil, fmt.Errorf("reference engine not built (%s): run `rake build`", bin)
	}
	out, err := run(exec.Command(bin, "references"), irText)
	if err != nil {
		return nil, fmt.Errorf("reference check failed: %w", err)
	}
	var res referenceResult
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		return nil, fmt.Errorf("reference check returned unreadable output: %w", err)
	}
	return &res, nil
}

// --- authority gate (Rust, IF-1) ----------------------------------------------

type gateDecision struct {
	GateState string `json:"gate_state"`
	Detail    string `json:"detail"`
	Matched   bool   `json:"matched"`
}

// checkProviderCallGate asks whether a credit-spending provider call is authorized right now.
//
// No envelope is passed because none exists: nothing has authorized a generation. The gate is
// asked anyway rather than the answer being assumed, so the refusal recorded in the ledger is the
// gate's, not the pipeline's opinion of what the gate would have said.
func checkProviderCallGate(repo string, irDigest string, nowMs int64) (*gateDecision, error) {
	bin := root(repo, "core", "rust", "target", "debug", "b1ledger")
	if _, err := os.Stat(bin); err != nil {
		return nil, fmt.Errorf("trusted core not built (%s): run `rake build`", bin)
	}

	input := canon.NewObject().
		Set("envelope", canon.Null{}).
		Set("proposed", canon.NewObject().
			Set("action_kind", canon.String("provider_call")).
			Set("target", canon.String(irDigest)).
			Set("scope_entry", canon.String("provider_call")).
			Set("current_state_digest", canon.String(irDigest)).
			Set("current_plan_digest", canon.String(irDigest)).
			Set("now_ms", canon.Int(nowMs)))

	text, err := canon.Canonicalize(input)
	if err != nil {
		return nil, err
	}

	// Exit 4 is a closed gate — the expected answer here, and not a failure.
	out, err := run(exec.Command(bin, "gate"), text, 4)
	if err != nil {
		return nil, fmt.Errorf("gate check failed: %w", err)
	}
	var d gateDecision
	if err := json.Unmarshal([]byte(out), &d); err != nil {
		return nil, fmt.Errorf("gate returned unreadable output: %w", err)
	}
	return &d, nil
}

// --- ledger (Rust, IF-1) -------------------------------------------------------

// appendRecord hands the record's content to the trusted core, which assigns its position and
// seals it. Go deliberately does not compute seq, prev_link or record_id: the integrity guarantee
// belongs to the component that exists to hold it.
func appendRecord(repo string, body canon.Value) (string, error) {
	bin := root(repo, "core", "rust", "target", "debug", "b1ledger")
	text, err := canon.Canonicalize(body)
	if err != nil {
		return "", err
	}
	out, err := run(exec.Command(bin, "append", root(repo, "state", "ledger.jsonl")), text)
	if err != nil {
		return "", fmt.Errorf("ledger append refused: %w", err)
	}
	return strings.TrimSpace(out), nil
}

func compile(repo string, irText string) (canon.Value, error) {
	cmd := exec.Command("java", "-cp", root(repo, "engine/jvm/java/build"), "b1.compiler.Compile")
	out, err := run(cmd, irText)
	if err != nil {
		return nil, fmt.Errorf("compiler failed: %w", err)
	}
	return canon.Parse(out)
}

// Run executes the loop as far as the authorized route permits.
func Run(repo, irPath, outDir string) (*Result, error) {
	irBytes, err := os.ReadFile(irPath)
	if err != nil {
		return nil, fmt.Errorf("cannot read IR: %w", err)
	}
	irText := string(irBytes)
	nowMs := time.Now().UnixMilli()

	irValue, err := canon.Parse(irText)
	if err != nil {
		return nil, fmt.Errorf("IR is not a valid B1-CANON-1 document (%s)", canon.Token(err))
	}
	irDigestHex, err := canon.DigestValue(irValue)
	if err != nil {
		return nil, err
	}

	res := &Result{IRDigest: canon.B1C1(irDigestHex)}
	res.Stages = append(res.Stages, Stage{"ingest_ir", "RAN", "IR parsed and digested"})

	// Reference roles are checked before anything else runs. A reference reaching outside its role
	// is a specification error, and compiling it into a package would let it reach a provider.
	refs, err := checkReferences(repo, irText)
	if err != nil {
		return nil, err
	}
	if !refs.Admissible {
		details := make([]string, 0, len(refs.Findings))
		for _, f := range refs.Findings {
			if f.Kind != "OVERLAPPING_AUTHORITY" {
				details = append(details, f.Detail)
			}
		}
		res.Stages = append(res.Stages, Stage{"reference_roles", "REFUSED", strings.Join(details, "; ")})
		return res, fmt.Errorf("reference bindings are inadmissible:\n  - %s",
			strings.Join(details, "\n  - "))
	}
	overlaps := 0
	for _, f := range refs.Findings {
		if f.Kind == "OVERLAPPING_AUTHORITY" {
			overlaps++
		}
	}
	// The count matters: "no findings" alone cannot distinguish a clean set of three bindings from
	// an IR that bound none at all.
	refDetail := fmt.Sprintf("%d binding(s) checked, all within their roles", refs.BindingsChecked)
	if refs.BindingsChecked == 0 {
		refDetail = "no reference bindings to check"
	} else if overlaps > 0 {
		refDetail = fmt.Sprintf("%d binding(s) checked; %d overlapping-authority note(s) to review",
			refs.BindingsChecked, overlaps)
	}
	res.Stages = append(res.Stages, Stage{"reference_roles", "RAN", refDetail})

	caps := discovery.Discover()
	route, reason := discovery.SelectRoute(caps)
	res.Route, res.RouteReason = route, reason
	res.Stages = append(res.Stages, Stage{"provider_discovery", "RAN",
		fmt.Sprintf("%d provider(s) probed; route %s", len(caps), route)})

	compiled, err := compile(repo, irText)
	if err != nil {
		return nil, err
	}
	res.Stages = append(res.Stages, Stage{"compile", "RAN", "provider-neutral compilation completed"})

	// The gate decides whether a credit-spending call may happen. Asked, not assumed.
	gate, err := checkProviderCallGate(repo, res.IRDigest, nowMs)
	if err != nil {
		return nil, err
	}
	res.GateState, res.GateDetail = gate.GateState, gate.Detail
	res.Stages = append(res.Stages, Stage{"authority_gate", "RAN",
		fmt.Sprintf("%s — %s", gate.GateState, gate.Detail)})

	res.ExecutionStatus = "NOT_EXECUTED"
	res.Outcome = "NOT_EXECUTED"
	generationDetail := gate.Detail
	if route == discovery.RouteEPlanningOnly {
		generationDetail = "no authorized rendering provider; " + gate.Detail
	}
	res.Stages = append(res.Stages, Stage{"generate", "NOT_EXECUTED", generationDetail})
	for _, s := range []string{"ingest_media", "analyze", "score", "verify"} {
		res.Stages = append(res.Stages, Stage{s, "NOT_EXECUTED", "no media was generated, so there is nothing to measure"})
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
	pkg.Set("gate_state", canon.String(gate.GateState))
	pkg.Set("gate_detail", canon.String(gate.Detail))

	capsArr := canon.Array{}
	for _, c := range caps {
		capsArr = append(capsArr, c.Value())
	}
	pkg.Set("capability_map", capsArr)

	pkg.Set("notes", canon.Array{
		canon.String("No media was generated. Every provider-facing field is a specification, not a result."),
		canon.String("Provider request shapes are CONTRACT_UNVERIFIED: no live provider contract has been observed."),
		canon.String("Quality vector and continuity state are absent because there is no output to measure."),
		canon.String("Generation did not occur because the authority gate is " + gate.GateState + "."),
	})
	pkg.Set("compiled_at_ms", canon.Int(nowMs))

	res.Package = pkg

	if outDir != "" {
		if err := os.MkdirAll(outDir, 0o755); err != nil {
			return nil, err
		}
		text, err := canon.Canonicalize(pkg)
		if err != nil {
			return nil, err
		}
		pkgDigest, err := canon.DigestValue(pkg)
		if err != nil {
			return nil, err
		}
		res.PackagePath = filepath.Join(outDir, "package-"+pkgDigest[:16]+".json")
		if err := os.WriteFile(res.PackagePath, []byte(text+"\n"), 0o644); err != nil {
			return nil, err
		}
	}

	// One record per run. Receipt, observed effect and postcondition are all null, so nothing here
	// can be mistaken for a generation that happened.
	record := canon.NewObject().
		Set("goal", canon.String("Produce a provider-ready generation package for the supplied IR")).
		Set("derived_need", canon.String("The operator asked for a plan over "+filepath.Base(irPath))).
		Set("origin", canon.String("U")).
		Set("causal_parents", canon.Array{}).
		Set("authority", canon.String("operator")).
		Set("authorization_ref", canon.Null{}).
		Set("envelope_digest", canon.Null{}).
		Set("effect_time_validation", canon.NewObject().
			Set("checked_at_ms", canon.Int(nowMs)).
			Set("gate_state", canon.String(gate.GateState)).
			Set("recomputed_envelope_digest", canon.Null{}).
			Set("matched", canon.Bool(gate.Matched)).
			Set("detail", canon.String(gate.Detail))).
		Set("executor", canon.String("b1-orchestrator")).
		Set("execution_identity", canon.String(fmt.Sprintf("local/pid-%d", os.Getpid()))).
		Set("attempt_identity", canon.String(fmt.Sprintf("plan-%d", nowMs))).
		Set("action", canon.NewObject().
			Set("kind", canon.String("compile_package")).
			Set("summary", canon.String("Compile a provider-ready generation package")).
			Set("target", canon.String(res.IRDigest)).
			Set("persistent", canon.Bool(false))).
		Set("receipt", canon.Null{}).
		Set("observed_effect", canon.Null{}).
		Set("objective_postcondition", canon.Null{}).
		Set("persistent_id", func() canon.Value {
			if res.PackagePath == "" {
				return canon.Null{}
			}
			rel, _ := filepath.Rel(repo, res.PackagePath)
			return canon.String(rel)
		}()).
		Set("user_visible", canon.Bool(true)).
		Set("reason_persisted", canon.String("the compiled package is the deliverable under PLANNING_ONLY")).
		Set("effect_class", canon.String("REVERSIBLE")).
		Set("evidence", canon.Array{
			canon.NewObject().
				Set("kind", canon.String("route_selection")).
				Set("detail", canon.String(reason)),
			canon.NewObject().
				Set("kind", canon.String("authority_gate")).
				Set("detail", canon.String(gate.GateState+" — "+gate.Detail)),
			canon.NewObject().
				Set("kind", canon.String("reference_roles")).
				Set("detail", canon.String(refDetail)),
		}).
		Set("present_validity", canon.String("WORKING_ASSUMPTION")).
		Set("observed_at_ms", canon.Int(nowMs))

	recordID, err := appendRecord(repo, record)
	if err != nil {
		return nil, err
	}
	res.RecordID = recordID
	res.Stages = append(res.Stages, Stage{"ledger", "RAN", "record " + recordID[:22] + "… appended and sealed"})

	return res, nil
}
