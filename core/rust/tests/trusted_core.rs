//! Tests for the trusted core.
//!
//! These establish success criteria S2 (the ledger is tamper-evident) and S3 (the authority gate
//! closes on staleness). They are written to *fail loudly* if the guarantees regress, because both
//! properties are the kind that silently stop holding.

use b1_ledger::authority::{check_at_effect_time, detect_anomalies, Envelope, GateState, Policy, ProposedEffect};
use b1_ledger::canon::{digest_text, digest_value, parse, Json};
use b1_ledger::ledger::*;
use b1_ledger::sha256::sha256_hex;

// --- SHA-256 against published vectors ---------------------------------------
//
// "Our implementations agree" would prove nothing if all of them were wrong the same way, so the
// base primitive is checked against values from outside this repository.

#[test]
fn sha256_matches_published_vectors() {
    assert_eq!(
        sha256_hex(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        sha256_hex(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    );
    // Exercises the two-block padding path.
    assert_eq!(
        sha256_hex(&vec![b'a'; 56]),
        "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
    );
    assert_eq!(
        sha256_hex(&vec![b'a'; 1_000_000]),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    );
}

#[test]
fn canon_matches_known_digests() {
    assert_eq!(
        digest_text("{}").unwrap(),
        "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
    );
    assert_eq!(
        digest_text("[]").unwrap(),
        "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
    );
    // Member order and insignificant whitespace must not affect identity.
    assert_eq!(
        digest_text(r#"{"b":1,"a":2}"#).unwrap(),
        digest_text("  { \"a\" : 2 , \"b\" : 1 }  ").unwrap()
    );
    // An escaped surrogate pair and the literal character are the same document.
    assert_eq!(
        digest_text(r#"{"x":"🎬"}"#).unwrap(),
        digest_text("{\"x\":\"\u{1F3AC}\"}").unwrap()
    );
}

// --- helpers ------------------------------------------------------------------

fn sample_record(seq: i64, prev: &str) -> Record {
    let mut r = Record {
        seq,
        prev_link: prev.to_string(),
        record_id: String::new(),
        goal: "Produce a verified continuation segment".into(),
        derived_need: "The previous segment was accepted and must be extended".into(),
        origin: Origin::U,
        causal_parents: vec![],
        authority: "user".into(),
        authorization_ref: None,
        envelope_digest: None,
        effect_time_validation: None,
        executor: "b1-orchestrator".into(),
        execution_identity: "local/process-1".into(),
        attempt_identity: "attempt-1".into(),
        action: Action {
            kind: "compile_package".into(),
            summary: "Compile a provider-ready generation package".into(),
            target: "segment-01".into(),
            persistent: false,
        },
        receipt: None,
        observed_effect: None,
        objective_postcondition: None,
        persistent_id: None,
        user_visible: true,
        reason_persisted: None,
        effect_class: EffectClass::Reversible,
        evidence: vec![],
        present_validity: Validity::WorkingAssumption,
        observed_at_ms: 1_700_000_000_000 + seq,
    };
    r.seal().unwrap();
    r
}

fn temp_path(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("b1-test-{}-{}", std::process::id(), name));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("ledger.jsonl").to_string_lossy().into_owned()
}

// --- S2: the ledger is tamper-evident ----------------------------------------

#[test]
fn s2_intact_chain_verifies() {
    let path = temp_path("intact");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);

    let mut prev = b1_ledger::canon::ZERO_LINK.to_string();
    for seq in 0..5 {
        let r = sample_record(seq, &prev);
        prev = r.record_id.clone();
        ledger.append(&r).unwrap();
    }

    let result = ledger.verify().unwrap();
    assert!(matches!(result, Ok(5)), "expected 5 verified records, got {result:?}");
}

#[test]
fn s2_altering_a_record_breaks_its_digest() {
    let path = temp_path("altered");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);

    let mut prev = b1_ledger::canon::ZERO_LINK.to_string();
    for seq in 0..3 {
        let r = sample_record(seq, &prev);
        prev = r.record_id.clone();
        ledger.append(&r).unwrap();
    }

    // Change one character of one field, leaving the carried record_id intact — the shape a silent
    // corruption or a quiet "fix" to history actually takes.
    let content = std::fs::read_to_string(&path).unwrap();
    let tampered = content.replacen("segment-01", "segment-99", 1);
    assert_ne!(content, tampered, "the fixture must actually change");
    std::fs::write(&path, tampered).unwrap();

    match ledger.verify().unwrap() {
        Err(ChainError::RecordAltered { seq, .. }) => assert_eq!(seq, 0),
        other => panic!("tampering was not detected: {other:?}"),
    }
}

#[test]
fn s2_removing_a_record_breaks_the_chain() {
    let path = temp_path("spliced");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);

    let mut prev = b1_ledger::canon::ZERO_LINK.to_string();
    for seq in 0..4 {
        let r = sample_record(seq, &prev);
        prev = r.record_id.clone();
        ledger.append(&r).unwrap();
    }

    let content = std::fs::read_to_string(&path).unwrap();
    let mut lines: Vec<&str> = content.lines().collect();
    lines.remove(1); // splice out the middle of history
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();

    match ledger.verify().unwrap() {
        Err(ChainError::SequenceGap { .. }) | Err(ChainError::LinkBroken { .. }) => {}
        other => panic!("splicing was not detected: {other:?}"),
    }
}

// --- L3: a receipt is not an effect, and an effect is not objective success ---

#[test]
fn l3_receipt_alone_is_never_verified() {
    let mut r = sample_record(0, b1_ledger::canon::ZERO_LINK);

    assert_eq!(r.outcome(), Outcome::NotExecuted, "nothing dispatched yet");

    r.receipt = Some(Receipt {
        executor_claim: "provider reported success".into(),
        status_code: Some("200".into()),
        received_at_ms: 1,
    });
    assert_eq!(
        r.outcome(),
        Outcome::InDoubt,
        "a provider saying `succeeded` must never reach VERIFIED on its own"
    );

    r.observed_effect = Some(ObservedEffect {
        observation: "media retrieved and decoded".into(),
        observer: "b1-media".into(),
        observed_at_ms: 2,
        media_digest: Some("b1c1:".to_string() + &"a".repeat(64)),
    });
    assert_eq!(
        r.outcome(),
        Outcome::InDoubt,
        "observing an effect is still not evidence the objective was met"
    );

    r.objective_postcondition = Some(Postcondition {
        statement: "segment continues the prior gait cycle".into(),
        satisfied: true,
        method: "continuity gate".into(),
        unmet: vec![],
    });
    assert_eq!(r.outcome(), Outcome::Verified);
}

// --- caller-supplied bodies: sealing and chaining stay here -------------------

fn body(summary: &str) -> Json {
    Json::obj(vec![
        ("goal", Json::s("Produce a verified continuation segment")),
        ("derived_need", Json::s("The orchestrator compiled a package")),
        ("origin", Json::s("M")),
        ("causal_parents", Json::Arr(vec![])),
        ("authority", Json::s("system")),
        ("executor", Json::s("b1-orchestrator")),
        ("execution_identity", Json::s("local/process-1")),
        ("attempt_identity", Json::s("attempt-1")),
        (
            "action",
            Json::obj(vec![
                ("kind", Json::s("compile_package")),
                ("summary", Json::s(summary)),
                ("target", Json::s("segment-01")),
                ("persistent", Json::Bool(false)),
            ]),
        ),
        ("receipt", Json::Null),
        ("observed_effect", Json::Null),
        ("objective_postcondition", Json::Null),
        ("authorization_ref", Json::Null),
        ("envelope_digest", Json::Null),
        ("effect_time_validation", Json::Null),
        ("persistent_id", Json::Null),
        ("user_visible", Json::Bool(true)),
        ("reason_persisted", Json::Null),
        ("effect_class", Json::s("REVERSIBLE")),
        ("evidence", Json::Arr(vec![])),
        ("proof", Json::Null),
        ("recovery_state", Json::Null),
        ("present_validity", Json::s("WORKING_ASSUMPTION")),
        ("observed_at_ms", Json::Int(1_700_000_000_000)),
    ])
}

#[test]
fn seal_and_append_assigns_position_and_chains() {
    let path = temp_path("sealed");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);

    let first = ledger.seal_and_append(&body("first")).unwrap();
    let second = ledger.seal_and_append(&body("second")).unwrap();
    assert_ne!(first, second);

    // The chain the caller never touched verifies.
    assert!(matches!(ledger.verify().unwrap(), Ok(2)));

    let lines = ledger.read_lines().unwrap();
    let rec0 = b1_ledger::canon::parse(&lines[0]).unwrap();
    let rec1 = b1_ledger::canon::parse(&lines[1]).unwrap();

    assert_eq!(rec0.get("seq").and_then(Json::as_int), Some(0));
    assert_eq!(rec1.get("seq").and_then(Json::as_int), Some(1));
    assert_eq!(
        rec0.get("prev_link").and_then(Json::as_str),
        Some(b1_ledger::canon::ZERO_LINK)
    );
    assert_eq!(
        rec1.get("prev_link").and_then(Json::as_str),
        Some(first.as_str()),
        "the second record must link to the first"
    );
    assert_eq!(rec1.get("record_id").and_then(Json::as_str), Some(second.as_str()));
}

#[test]
fn seal_and_append_refuses_a_body_claiming_its_own_position() {
    let path = temp_path("forged");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);
    ledger.seal_and_append(&body("genuine")).unwrap();

    // A caller that picks its own seq, link or id is not recording — it is choosing where in
    // history to appear. Overwriting the field silently would hide the attempt.
    for reserved in ["seq", "prev_link", "record_id"] {
        let Json::Obj(mut members) = body("forged") else { unreachable!() };
        members.insert(
            reserved.to_string(),
            if reserved == "seq" { Json::Int(0) } else { Json::s("b1c1:".to_string() + &"0".repeat(64)) },
        );
        let result = ledger.seal_and_append(&Json::Obj(members));
        assert!(
            matches!(result, Err(b1_ledger::ledger::SealError::ReservedField(f)) if f == reserved),
            "a body setting `{reserved}` must be refused, got {result:?}"
        );
    }

    // The refusals left the chain untouched.
    assert!(matches!(ledger.verify().unwrap(), Ok(1)));
}

#[test]
fn seal_and_append_refuses_an_incomplete_body() {
    let path = temp_path("incomplete");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);

    let Json::Obj(mut members) = body("missing pieces") else { unreachable!() };
    members.remove("executor");
    members.remove("attempt_identity");

    match ledger.seal_and_append(&Json::Obj(members)) {
        Err(b1_ledger::ledger::SealError::ContractViolation(violations)) => {
            for field in ["executor", "attempt_identity"] {
                assert!(
                    violations.iter().any(|v| matches!(
                        v, Violation::MissingRequired { field: f, .. } if f == field
                    )),
                    "`{field}` must be named in the refusal"
                );
            }
        }
        other => panic!("an incomplete body must be refused, got {other:?}"),
    }
    assert_eq!(ledger.read_lines().unwrap().len(), 0);
}

#[test]
fn a_sealed_record_still_classifies_as_not_executed() {
    let path = temp_path("classify");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);
    ledger.seal_and_append(&body("nothing was dispatched")).unwrap();

    let line = &ledger.read_lines().unwrap()[0];
    let rec = b1_ledger::canon::parse(line).unwrap();

    // Receipt, observed effect and postcondition all absent: there is nothing here that could be
    // mistaken for a success.
    for f in ["receipt", "observed_effect", "objective_postcondition"] {
        assert!(matches!(rec.get(f), Some(Json::Null)), "{f} should be null");
    }
}

// --- B1-SCHEMA-1: the contract is enforced, not merely published ---------------

use b1_ledger::schema::{self, Violation};

fn schema_of(json: &str) -> Json {
    b1_ledger::canon::parse(json).unwrap()
}

#[test]
fn required_means_present_not_merely_non_null() {
    // The distinction the whole enforcement rests on: a required, nullable field must appear
    // carrying null. Omitting it is a violation, because "not recorded" and "recorded as nothing"
    // are different claims.
    let s = schema_of(
        r#"{"type":"object","properties":{"a":{"anyOf":[{"type":"string"},{"type":"null"}]}},
            "required":["a"],"additionalProperties":false}"#,
    );

    assert!(schema::validate(&schema_of(r#"{"a":null}"#), &s).is_empty());
    assert!(schema::validate(&schema_of(r#"{"a":"x"}"#), &s).is_empty());

    let violations = schema::validate(&schema_of("{}"), &s);
    assert!(
        matches!(violations.as_slice(), [Violation::MissingRequired { field, .. }] if field == "a"),
        "omitting a required nullable field must be a violation, got {violations:?}"
    );
}

#[test]
fn an_unknown_keyword_is_refused_even_where_the_document_never_reaches_it() {
    // Detecting schema defects only while walking the document would make enforcement depend on
    // what the document happens to contain — an unknown keyword on a field nothing populates would
    // never be reached, and the validator would keep reporting valid over an unchecked constraint.
    let s = schema_of(
        r#"{"type":"object","properties":{"never_present":{"type":"string","minLength":3}},
            "additionalProperties":false}"#,
    );

    let violations = schema::validate(&schema_of("{}"), &s);
    assert!(
        violations.iter().any(|v| matches!(v, Violation::UnknownKeyword { keyword, .. } if keyword == "minLength")),
        "an unknown keyword must be found by scanning the schema, got {violations:?}"
    );
}

#[test]
fn an_unsupported_pattern_is_refused_rather_than_skipped() {
    let s = schema_of(
        r#"{"type":"object","properties":{"a":{"type":"string","pattern":"^(foo|bar)+$"}},
            "additionalProperties":false}"#,
    );
    let violations = schema::validate(&schema_of(r#"{"a":"foo"}"#), &s);
    assert!(
        violations.iter().any(|v| matches!(v, Violation::UnsupportedPattern { .. })),
        "skipping a pattern it cannot evaluate would report a result never established"
    );
}

#[test]
fn supported_patterns_both_match_and_reject() {
    let s = schema_of(
        r#"{"type":"object","properties":{"d":{"type":"string","pattern":"^b1c1:[0-9a-f]{64}$"}},
            "additionalProperties":false}"#,
    );
    let good = format!(r#"{{"d":"b1c1:{}"}}"#, "a".repeat(64));
    assert!(schema::validate(&schema_of(&good), &s).is_empty());

    let short = format!(r#"{{"d":"b1c1:{}"}}"#, "a".repeat(63));
    assert!(!schema::validate(&schema_of(&short), &s).is_empty(), "length is checked");

    let nonhex = format!(r#"{{"d":"b1c1:{}"}}"#, "z".repeat(64));
    assert!(!schema::validate(&schema_of(&nonhex), &s).is_empty(), "character class is checked");
}

#[test]
fn every_violation_is_reported_not_only_the_first() {
    // Three missing fields and thirty are different situations; reporting them identically discards
    // the signal that tells them apart.
    let s = schema_of(
        r#"{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"},
            "c":{"type":"string"}},"required":["a","b","c"],"additionalProperties":false}"#,
    );
    assert_eq!(schema::validate(&schema_of("{}"), &s).len(), 3);
}

#[test]
fn the_generated_contracts_are_all_fully_enforceable() {
    // Every shipped schema must lie inside B1-SCHEMA-1. If one drifts outside, enforcement against
    // it silently becomes partial, so this fails rather than letting that happen quietly.
    for name in [
        "ledger-record.schema.json",
        "b1-video-ir.schema.json",
        "authority-envelope.schema.json",
        "generation-package.schema.json",
        "quality-vector.schema.json",
        "continuity-state.schema.json",
        "provider-capability.schema.json",
        "evidence-record.schema.json",
        "failure-localization.schema.json",
    ] {
        let Some(path) = schema::find_generated(name) else {
            panic!("{name} not found — run `npm run generate` in contracts/");
        };
        let s = schema::load(&path).unwrap();
        let defects: Vec<_> = schema::validate(&schema_of("{}"), &s)
            .into_iter()
            .filter(Violation::is_schema_defect)
            .collect();
        assert!(defects.is_empty(), "{name} is not fully enforceable: {defects:?}");
    }
}

/// The exact document that pass 01 accepted, sealed and chained. It must now be refused.
#[test]
fn a_record_cannot_claim_verified_with_nothing_behind_it() {
    let path = temp_path("l3-hole");
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::new(&path);

    let thin = schema_of(
        r#"{"goal":"g","derived_need":"d","origin":"M","authority":"a","executor":"e",
            "execution_identity":"ei","attempt_identity":"ai",
            "action":{"kind":"k","summary":"s","target":"t","persistent":false},
            "present_validity":"VERIFIED"}"#,
    );

    match ledger.seal_and_append(&thin) {
        Err(b1_ledger::ledger::SealError::ContractViolation(violations)) => {
            // The three fields law L3 depends on must be among the refusals; without them present
            // a record asserts VERIFIED and nothing can contradict it.
            for field in ["receipt", "observed_effect", "objective_postcondition"] {
                assert!(
                    violations.iter().any(|v| matches!(
                        v, Violation::MissingRequired { field: f, .. } if f == field
                    )),
                    "`{field}` must be refused as absent"
                );
            }
        }
        other => panic!("the thin record must be refused, got {other:?}"),
    }

    assert_eq!(
        ledger.read_lines().unwrap().len(),
        0,
        "a refused record must not reach the chain"
    );
}

// --- S3: the authority gate ---------------------------------------------------

fn envelope(state_digest: &str, plan_digest: &str) -> Envelope {
    Envelope {
        envelope_id: "env-1".into(),
        action_kind: "write_files".into(),
        action_summary: "Build the system described in the plan".into(),
        target: "/home/user/B1u.Ta".into(),
        scope: vec!["repo_write".into(), "branch_push".into()],
        expected_effect: "Files created and committed on the designated branch".into(),
        relevant_state_digest: state_digest.into(),
        plan_digest: plan_digest.into(),
        causal_objective: "Deliver the orchestrator".into(),
        effect_class: EffectClass::Reversible,
        authorized_at_ms: 1_000_000,
        authorized_by: "user".into(),
        max_age_ms: 60_000,
    }
}

fn proposed(state: &str, plan: &str, now_ms: i64) -> ProposedEffect {
    ProposedEffect {
        action_kind: "write_files".into(),
        target: "/home/user/B1u.Ta".into(),
        scope_entry: "repo_write".into(),
        current_state_digest: state.into(),
        current_plan_digest: plan.into(),
        now_ms,
    }
}

#[test]
fn s3_gate_opens_when_authorization_still_describes_the_effect() {
    let env = envelope("state-a", "plan-a");
    let d = check_at_effect_time(Some(&env), &proposed("state-a", "plan-a", 1_010_000), Policy::default());
    assert_eq!(d.state, GateState::Open, "{}", d.detail);
}

#[test]
fn s3_gate_closes_when_the_assumed_state_drifted() {
    let env = envelope("state-a", "plan-a");
    // The plan is unchanged, but the world the plan assumed is not.
    let d = check_at_effect_time(Some(&env), &proposed("state-b", "plan-a", 1_010_000), Policy::default());
    assert_eq!(d.state, GateState::ClosedStale, "{}", d.detail);
}

#[test]
fn s3_gate_closes_when_the_plan_changed() {
    let env = envelope("state-a", "plan-a");
    let d = check_at_effect_time(Some(&env), &proposed("state-a", "plan-b", 1_010_000), Policy::default());
    assert_eq!(d.state, GateState::ClosedStale, "{}", d.detail);
}

#[test]
fn s3_gate_closes_when_expired() {
    let env = envelope("state-a", "plan-a");
    let d = check_at_effect_time(Some(&env), &proposed("state-a", "plan-a", 2_000_000), Policy::default());
    assert_eq!(d.state, GateState::ClosedExpired, "{}", d.detail);
}

#[test]
fn s3_absence_of_an_envelope_is_closed_not_open() {
    let d = check_at_effect_time(None, &proposed("state-a", "plan-a", 1_010_000), Policy::default());
    assert_eq!(
        d.state,
        GateState::ClosedUnauthorized,
        "the gate must default to closed; absence is never an implicit open"
    );
}

#[test]
fn s3_authorization_for_one_effect_does_not_authorize_another() {
    let env = envelope("state-a", "plan-a");

    let mut other_scope = proposed("state-a", "plan-a", 1_010_000);
    other_scope.scope_entry = "provider_call".into(); // not in the envelope's scope
    assert_eq!(
        check_at_effect_time(Some(&env), &other_scope, Policy::default()).state,
        GateState::ClosedScopeViolation
    );

    let mut other_target = proposed("state-a", "plan-a", 1_010_000);
    other_target.target = "/etc".into();
    assert_eq!(
        check_at_effect_time(Some(&env), &other_target, Policy::default()).state,
        GateState::ClosedScopeViolation
    );

    let mut other_action = proposed("state-a", "plan-a", 1_010_000);
    other_action.action_kind = "delete_files".into();
    assert_eq!(
        check_at_effect_time(Some(&env), &other_action, Policy::default()).state,
        GateState::ClosedScopeViolation
    );
}

#[test]
fn s3_unknown_recovery_closes_the_gate_under_default_policy() {
    let mut env = envelope("state-a", "plan-a");
    env.effect_class = EffectClass::Unknown;
    let d = check_at_effect_time(Some(&env), &proposed("state-a", "plan-a", 1_010_000), Policy::default());
    assert_eq!(
        d.state,
        GateState::ClosedUnknownRecovery,
        "recovery limits must be known before authorization, not discovered afterwards"
    );
}

// --- L10: P/E anomalies -------------------------------------------------------

#[test]
fn l10_unaccounted_state_is_flagged_not_normalized() {
    let observed = vec!["res-1".to_string(), "res-2".to_string(), "res-3".to_string()];
    let accounted = vec!["res-1".to_string(), "res-3".to_string()];

    let anomalies = detect_anomalies(&observed, &accounted);
    assert_eq!(anomalies.len(), 1);
    assert_eq!(anomalies[0].observed, "res-2");
    assert_eq!(
        anomalies[0].origin_guess, "UNKNOWN",
        "guessing between P and E would itself be a fabricated attribution"
    );
}

// --- record identity ----------------------------------------------------------

#[test]
fn record_id_excludes_itself_and_covers_everything_else() {
    let r = sample_record(0, b1_ledger::canon::ZERO_LINK);

    // The id is the digest of the body, and the body carries no record_id.
    assert_eq!(r.record_id, b1_ledger::canon::b1c1(&digest_value(&r.body()).unwrap()));
    assert!(r.body().get("record_id").is_none());

    // Any field change changes the identity.
    let mut altered = r.clone();
    altered.derived_need = "something else".into();
    altered.seal().unwrap();
    assert_ne!(r.record_id, altered.record_id);

    // The serialized record round-trips through the canonical form.
    let line = b1_ledger::canon::canonicalize(&r.to_json()).unwrap();
    let back = parse(&line).unwrap();
    assert_eq!(back.get("record_id").and_then(Json::as_str), Some(r.record_id.as_str()));
}
