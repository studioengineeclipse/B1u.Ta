// Package discovery determines which execution routes actually exist.
// Normative: SPEC/70-provider-routes.md.
//
// The governing rule is that access is never assumed. Two confusions are structurally prevented
// here rather than left to discipline:
//
//   - A credential's existence is not an entitlement. Holding a key proves a key exists; it does
//     not prove the account has the model, the quota, the region or the feature. Entitlement is
//     established by an observation that succeeded, or it stays UNKNOWN.
//   - Route B (Neta router to Seedance) is not implied by Route C (Neta's own API). A NETA_TOKEN
//     authorizes Neta's capabilities; routing to Seedance needs its own authorization.
package discovery

import (
	"os"
	"sort"
	"time"

	"b1/engine/internal/canon"
)

type Route string

const (
	RouteAOfficialSeedance Route = "A_OFFICIAL_SEEDANCE"
	RouteBNetaRouter       Route = "B_NETA_ROUTER"
	RouteCNetaNative       Route = "C_NETA_NATIVE"
	RouteDOtherAuthorized  Route = "D_OTHER_AUTHORIZED"
	RouteEPlanningOnly     Route = "E_PLANNING_ONLY"
)

type ContractStatus string

const (
	ContractVerified   ContractStatus = "VERIFIED"
	ContractUnverified ContractStatus = "CONTRACT_UNVERIFIED"
	ContractUnknown    ContractStatus = "UNKNOWN"
)

// Tri is a three-valued flag. A plain bool cannot express the difference between "this provider
// does not support extension" and "we have not established whether it does" — different facts with
// different consequences (law L5).
type Tri int

const (
	TriUnknown Tri = iota
	TriTrue
	TriFalse
)

func (t Tri) Value() canon.Value {
	switch t {
	case TriTrue:
		return canon.Bool(true)
	case TriFalse:
		return canon.Bool(false)
	default:
		return canon.Null{}
	}
}

func (t Tri) String() string {
	switch t {
	case TriTrue:
		return "yes"
	case TriFalse:
		return "no"
	default:
		return "UNKNOWN"
	}
}

// Capability records what is actually known about a provider. Every field that could not be
// observed stays nil/Unknown; nothing is populated from documentation the system has not fetched,
// or from what a similar provider does.
type Capability struct {
	ProviderID string
	Route      Route

	AuthMethod string
	BaseURL    string

	// nil means not established. An empty slice would mean "observed to be empty" — a claim.
	AvailableModels []string
	InputModalities []string

	DurationLimitsMs  *[2]int64
	MaxWidthPx        *int
	MaxReferences     *int
	ExtensionSupport  Tri
	AudioSupport      Tri

	CredentialPresent   bool
	EntitlementObserved Tri
	VerifiedAtMs        *int64
	EvidenceSource      string
	ContractStatus      ContractStatus
}

// credentialSpec names the environment variables that would authorize each route. Only names are
// ever read for presence; values are never read into memory here and never logged.
type credentialSpec struct {
	route     Route
	provider  string
	envVars   []string
	authNotes string
}

var specs = []credentialSpec{
	{
		route:     RouteAOfficialSeedance,
		provider:  "seedance-official",
		envVars:   []string{"SEEDANCE_API_KEY", "BYTEPLUS_API_KEY", "VOLCENGINE_API_KEY", "ARK_API_KEY"},
		authNotes: "official Seedance/BytePlus/Volcengine credential plus the required entitlement",
	},
	{
		route:    RouteBNetaRouter,
		provider: "neta-router",
		// Deliberately NOT NETA_TOKEN: a token granting Neta's own API does not authorize
		// routing to Seedance through it.
		envVars:   []string{"NETA_ROUTER_KEY"},
		authNotes: "documented router authorization; never inferred from NETA_TOKEN",
	},
	{
		route:     RouteCNetaNative,
		provider:  "neta-native",
		envVars:   []string{"NETA_TOKEN", "NETA_API_KEY"},
		authNotes: "Neta's own make_video / make_image / asset capabilities",
	},
	{
		route:     RouteDOtherAuthorized,
		provider:  "other-authorized",
		envVars:   []string{"B1_PROVIDER_URL"},
		authNotes: "capability identified and interface verified before use",
	},
}

func credentialPresent(names []string) bool {
	for _, n := range names {
		if v, ok := os.LookupEnv(n); ok && v != "" {
			return true
		}
	}
	return false
}

// PresentCredentialNames returns the names (never values) of the credentials that are set, so an
// operator can see what the system found without the system printing a secret.
func PresentCredentialNames() []string {
	var out []string
	for _, s := range specs {
		for _, n := range s.envVars {
			if v, ok := os.LookupEnv(n); ok && v != "" {
				out = append(out, n)
			}
		}
	}
	sort.Strings(out)
	return out
}

// Discover builds the capability map. It performs no network calls: presence of a credential is
// all that can be established without one, and this function is careful to claim only that.
//
// Entitlement stays UNKNOWN for every provider here. Establishing it requires a capability query
// that actually succeeded, which is a provider call — and provider calls are persistent effects
// requiring their own authorization (SPEC/40).
func Discover() []Capability {
	now := time.Now().UnixMilli()
	caps := make([]Capability, 0, len(specs))

	for _, s := range specs {
		present := credentialPresent(s.envVars)
		c := Capability{
			ProviderID:        s.provider,
			Route:             s.route,
			CredentialPresent: present,
			// Not observed, so not claimed — in either direction.
			EntitlementObserved: TriUnknown,
			ExtensionSupport:    TriUnknown,
			AudioSupport:        TriUnknown,
			ContractStatus:      ContractUnknown,
			EvidenceSource:      "environment probe: credential presence only, no provider call made",
		}
		if present {
			c.AuthMethod = s.authNotes
			c.VerifiedAtMs = &now
		}
		caps = append(caps, c)
	}
	return caps
}

// SelectRoute picks the execution route from what was actually established.
//
// A credential alone is not enough to select a rendering route: the contract must also have been
// verified, because compiling a request against a guessed contract spends credits to discover that
// the guess was wrong. Where a credential exists but the contract is unverified, the honest result
// is still PLANNING_ONLY, and the reason says so.
func SelectRoute(caps []Capability) (Route, string) {
	order := []Route{RouteAOfficialSeedance, RouteBNetaRouter, RouteCNetaNative, RouteDOtherAuthorized}

	var credentialed []Capability
	for _, want := range order {
		for _, c := range caps {
			if c.Route == want && c.CredentialPresent {
				credentialed = append(credentialed, c)
			}
		}
	}

	if len(credentialed) == 0 {
		return RouteEPlanningOnly, "no rendering provider is authorized: no credential found for any route"
	}

	for _, c := range credentialed {
		if c.ContractStatus == ContractVerified && c.EntitlementObserved == TriTrue {
			return c.Route, "credential present, entitlement observed and provider contract verified"
		}
	}

	return RouteEPlanningOnly,
		"credential present for " + string(credentialed[0].Route) +
			", but entitlement is unobserved and the provider contract is unverified; " +
			"verify the live contract before spending credits"
}

// Value renders the capability map as a B1-CANON-1 document.
func (c Capability) Value() canon.Value {
	obj := canon.NewObject()
	obj.Set("provider_id", canon.String(c.ProviderID))
	obj.Set("route", canon.String(string(c.Route)))
	obj.Set("credential_present", canon.Bool(c.CredentialPresent))
	obj.Set("entitlement_observed", c.EntitlementObserved.Value())
	obj.Set("extension_support", c.ExtensionSupport.Value())
	obj.Set("audio_support", c.AudioSupport.Value())
	obj.Set("contract_status", canon.String(string(c.ContractStatus)))
	obj.Set("evidence_source", canon.String(c.EvidenceSource))

	setOrNull := func(key, v string) {
		if v == "" {
			obj.Set(key, canon.Null{})
		} else {
			obj.Set(key, canon.String(v))
		}
	}
	setOrNull("auth_method", c.AuthMethod)
	setOrNull("base_url", c.BaseURL)

	if c.AvailableModels == nil {
		obj.Set("available_models", canon.Null{})
	} else {
		arr := canon.Array{}
		for _, m := range c.AvailableModels {
			arr = append(arr, canon.String(m))
		}
		obj.Set("available_models", arr)
	}

	if c.DurationLimitsMs == nil {
		obj.Set("duration_limits_ms", canon.Null{})
	} else {
		obj.Set("duration_limits_ms", canon.NewObject().
			Set("min", canon.Int(c.DurationLimitsMs[0])).
			Set("max", canon.Int(c.DurationLimitsMs[1])))
	}

	if c.MaxReferences == nil {
		obj.Set("reference_limits", canon.Null{})
	} else {
		obj.Set("reference_limits", canon.NewObject().
			Set("max_references", canon.Int(int64(*c.MaxReferences))))
	}

	if c.VerifiedAtMs == nil {
		obj.Set("currently_verified_at_ms", canon.Null{})
	} else {
		obj.Set("currently_verified_at_ms", canon.Int(*c.VerifiedAtMs))
	}
	return obj
}
