// Checks for the reference role algebra.
//
// The property under test is the one SPEC/10 §5 exists to protect: a reference influences the
// dimensions it was bound to and no others. That rule is easy to state and easy to lose, because
// nothing about attaching a reference makes its scope visible.

import Foundation

private var failures = 0

private func check(_ what: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok    \(what)")
    } else {
        print("  FAIL  \(what)" + (detail.isEmpty ? "" : "\n        \(detail)"))
        failures += 1
    }
}

private func binding(
    _ id: String,
    _ role: ReferenceRole,
    _ paths: [String],
    weight: Int64 = 500_000,
    rationale: String = "serves an identified requirement",
    detail: String? = nil
) -> ReferenceBinding {
    ReferenceBinding(id: id, role: role, roleDetail: detail, weightPPM: weight,
                     appliesTo: paths, rationale: rationale)
}

func runSelfTest() -> Int {
    failures = 0

    print("b1-canon-1 (swift)")
    do {
        check("{} digest matches the published value",
              try digestText("{}") == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        check("member order and whitespace are irrelevant",
              try digestText("{\"b\":1,\"a\":2}") == digestText("  { \"a\" : 2 , \"b\" : 1 }  "))
        check("an escaped surrogate pair equals the literal character",
              try digestText("{\"x\":\"\\ud83c\\udfac\"}") == digestText("{\"x\":\"\u{1F3AC}\"}"))
    } catch {
        check("canon smoke tests ran", false, "threw \(error)")
    }

    for (doc, expected) in [
        ("{\"a\":1.5}", "B1_ERR_NONINTEGER_NUMBER"),
        ("{\"a\":9007199254740992}", "B1_ERR_NONINTEGER_NUMBER"),
        ("{\"a b\":1}", "B1_ERR_KEY_SYNTAX"),
        ("{\"a\":1,\"a\":2}", "B1_ERR_DUPLICATE_KEY"),
        ("{\"a\":\"\\ud83c\"}", "B1_ERR_INVALID_UTF8"),
    ] {
        do {
            _ = try digestText(doc)
            check("\(doc) rejected", false, "it was accepted")
        } catch let e as B1Error {
            check("\(doc) rejected as \(expected)", e.token == expected, "got \(e.token)")
        } catch {
            check("\(doc) rejected", false, "unexpected error")
        }
    }

    print("reference role algebra")

    // The whole point: roles keep to their own dimensions.
    do {
        let r = analyze([
            binding("ref-identity", .characterIdentity, ["characters", "identity_constraints"]),
            binding("ref-motion", .motion, ["subject_motion", "animation_timing"]),
            binding("ref-env", .environment, ["environment", "depth_layers"]),
            binding("ref-style", .style, ["visual_style"]),
        ])
        check("cleanly separated roles are admissible", r.admissible,
              r.findings.map(\.detail).joined(separator: "; "))
    }

    // A style reference reaching into identity: the commonest way a chained sequence loses its
    // subject, and the case the forbidden-path rule exists for.
    do {
        let r = analyze([binding("ref-style", .style, ["visual_style", "characters"])])
        check("a style reference claiming identity is rejected", !r.admissible)
        check("it is reported as a forbidden path, not a generic scope error",
              r.findings.contains { $0.kind == .forbiddenPath && $0.path == "characters" },
              r.findings.map { "\($0.kind.rawValue):\($0.path ?? "-")" }.joined(separator: ", "))
    }

    do {
        let r = analyze([binding("ref-motion", .motion, ["subject_motion", "identity_constraints"])])
        check("a motion reference claiming identity is rejected", !r.admissible)
    }

    // Out of scope but not identity-touching: still a violation, differently named.
    do {
        let r = analyze([binding("ref-audio", .audio, ["audio_state", "camera_motion"])])
        check("a reference claiming a path its role does not govern is rejected", !r.admissible)
        check("it is reported as a scope violation",
              r.findings.contains { $0.kind == .scopeViolation && $0.path == "camera_motion" })
    }

    // Overlap is reported but is a decision, not an error.
    do {
        let r = analyze([
            binding("ref-env-a", .environment, ["environment"], weight: 900_000),
            binding("ref-env-b", .environment, ["environment"], weight: 300_000),
        ])
        check("overlapping authority is reported",
              r.findings.contains { $0.kind == .overlappingAuthority })
        check("overlap alone does not make a set inadmissible", r.admissible,
              "two references can legitimately inform the same dimension")
        check("the report names both references and their weights",
              r.findings.first { $0.kind == .overlappingAuthority }?.detail.contains("900000ppm") ?? false)
    }

    do {
        let r = analyze([binding("ref-x", .motion, ["subject_motion"], rationale: "  ")])
        check("a reference with no rationale is rejected", !r.admissible)
        check("it is named as a missing rationale",
              r.findings.contains { $0.kind == .missingRationale })
    }

    do {
        let r = analyze([binding("ref-x", .otherExplicit, ["visual_style"], detail: nil)])
        check("OTHER_EXPLICIT_ROLE without a stated role is rejected", !r.admissible)
    }

    do {
        let r = analyze([binding("ref-x", .motion, [])])
        check("a reference bound to no paths is rejected", !r.admissible,
              "it can influence nothing, so it is either a mistake or dead weight")
    }

    // VIDEO_CONTINUITY is the one role permitted to speak to continuity constraints.
    do {
        let r = analyze([binding("ref-prev", .videoContinuity,
                                 ["subject_motion", "camera_motion", "continuity_constraints"])])
        check("VIDEO_CONTINUITY may govern continuity constraints", r.admissible,
              r.findings.map(\.detail).joined(separator: "; "))

        let other = analyze([binding("ref-style", .style, ["continuity_constraints"])])
        check("no other role may", !other.admissible)
    }

    check("every role declares its permitted paths",
          ReferenceRole.allCases.allSatisfy { !$0.permittedPaths.isEmpty || $0 == .otherExplicit })

    print("")
    print(failures == 0 ? "PASSED: 0 failures" : "FAILED: \(failures) failure(s)")
    return failures == 0 ? 0 : 1
}
