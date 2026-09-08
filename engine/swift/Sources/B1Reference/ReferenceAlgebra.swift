// The reference role algebra. Normative: SPEC/10-b1-video-ir.md §5.
//
// Swift owns this because the role model is an algebra of closed cases: seventeen roles, each
// permitted to influence a specific set of IR paths, with conflicts arising where two references
// claim authority over the same path. Enums with associated values and exhaustive switching make
// the model total — a new role cannot be added without the compiler demanding its permitted paths.
//
// The rule being enforced is that no reference silently dominates dimensions it was not bound to.
// A reference bound as MOTION influences motion; if it also reshapes the character's face, that is
// not a stylistic side effect, it is the failure mode this file exists to catch.

import Foundation

enum ReferenceRole: String, CaseIterable {
    case characterIdentity = "CHARACTER_IDENTITY"
    case faceIdentity = "FACE_IDENTITY"
    case bodyDesign = "BODY_DESIGN"
    case costume = "COSTUME"
    case environment = "ENVIRONMENT"
    case object = "OBJECT"
    case style = "STYLE"
    case color = "COLOR"
    case composition = "COMPOSITION"
    case camera = "CAMERA"
    case motion = "MOTION"
    case animationTiming = "ANIMATION_TIMING"
    case pose = "POSE"
    case action = "ACTION"
    case videoContinuity = "VIDEO_CONTINUITY"
    case audio = "AUDIO"
    case otherExplicit = "OTHER_EXPLICIT_ROLE"

    /// The IR paths a reference in this role is permitted to influence.
    ///
    /// Exhaustive by construction: adding a case to the enum makes this switch incomplete and the
    /// build fails until its permitted paths are stated. A role whose authority was never declared
    /// would otherwise default to influencing nothing — or, worse, to being unchecked.
    var permittedPaths: Set<String> {
        switch self {
        case .characterIdentity:
            return ["characters", "identity_constraints"]
        case .faceIdentity:
            return ["characters", "identity_constraints"]
        case .bodyDesign:
            return ["characters"]
        case .costume:
            return ["characters", "material_behavior"]
        case .environment:
            return ["environment", "depth_layers", "background_elements", "lighting", "atmosphere"]
        case .object:
            return ["props", "foreground_elements", "midground_elements", "background_elements"]
        case .style:
            return ["visual_style", "material_behavior"]
        case .color:
            return ["visual_style", "lighting"]
        case .composition:
            return ["camera_state", "spatial_layout", "depth_layers"]
        case .camera:
            return ["camera_state", "camera_motion", "lens_behavior"]
        case .motion:
            return ["subject_motion", "secondary_motion", "animation_timing", "rhythm"]
        case .animationTiming:
            return ["animation_timing", "rhythm"]
        case .pose:
            return ["subject_motion"]
        case .action:
            return ["subject_motion", "interaction_graph"]
        case .videoContinuity:
            // The one role permitted to speak to continuity, because it *is* the previous verified
            // segment. Its breadth is the reason continuation priority ranks it first.
            return ["subject_motion", "camera_motion", "continuity_constraints", "animation_timing",
                    "final_frame_requirements"]
        case .audio:
            return ["audio_state"]
        case .otherExplicit:
            // Declares nothing implicitly: an explicit role must state its own scope, and until it
            // does it may influence nothing at all.
            return []
        }
    }

    /// Dimensions this role must never reach, whatever it declares. Identity is the one that
    /// matters most in practice: a style or motion reference that quietly reshapes a face is the
    /// commonest way a chained sequence loses its subject.
    var forbiddenPaths: Set<String> {
        switch self {
        case .style, .color, .motion, .animationTiming, .camera, .composition, .audio:
            return ["characters", "identity_constraints"]
        default:
            return []
        }
    }
}

struct ReferenceBinding {
    let id: String
    let role: ReferenceRole
    let roleDetail: String?
    let weightPPM: Int64
    let appliesTo: [String]
    let rationale: String
}

enum FindingKind: String {
    case scopeViolation = "SCOPE_VIOLATION"
    case forbiddenPath = "FORBIDDEN_PATH"
    case overlappingAuthority = "OVERLAPPING_AUTHORITY"
    case missingRationale = "MISSING_RATIONALE"
    case undeclaredExplicitRole = "UNDECLARED_EXPLICIT_ROLE"
    case emptyScope = "EMPTY_SCOPE"
}

struct Finding {
    let kind: FindingKind
    let referenceIds: [String]
    let path: String?
    let detail: String
}

struct AnalysisResult {
    let findings: [Finding]
    /// How many bindings were examined.
    ///
    /// Reported because "no findings" is ambiguous without it: an analysis that checked three
    /// bindings and found nothing wrong and one that checked none are very different facts, and
    /// only the count distinguishes them. Absence of evidence is not evidence of admissibility.
    let bindingsChecked: Int

    var admissible: Bool {
        !findings.contains { $0.kind != .overlappingAuthority }
    }
}

/// Checks a set of reference bindings against the role algebra.
///
/// Overlapping authority is reported but does not on its own make the set inadmissible: two
/// references can legitimately both inform the environment. What is inadmissible is a reference
/// reaching outside its role, and the distinction is kept because collapsing them would either
/// block legitimate work or wave through the failure that matters.
func analyze(_ bindings: [ReferenceBinding]) -> AnalysisResult {
    var findings = [Finding]()

    for b in bindings {
        if b.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(Finding(
                kind: .missingRationale, referenceIds: [b.id], path: nil,
                detail: "reference \(b.id) has no stated rationale; a reference is bound because it "
                    + "serves an identified requirement, not because it exists"))
        }

        if b.role == .otherExplicit && (b.roleDetail?.isEmpty ?? true) {
            findings.append(Finding(
                kind: .undeclaredExplicitRole, referenceIds: [b.id], path: nil,
                detail: "reference \(b.id) uses OTHER_EXPLICIT_ROLE without stating what that role is"))
        }

        if b.appliesTo.isEmpty {
            findings.append(Finding(
                kind: .emptyScope, referenceIds: [b.id], path: nil,
                detail: "reference \(b.id) declares no paths, so it can influence nothing; either "
                    + "bind it to a path or remove it"))
        }

        let permitted = b.role.permittedPaths
        let forbidden = b.role.forbiddenPaths

        for path in b.appliesTo {
            if forbidden.contains(path) {
                findings.append(Finding(
                    kind: .forbiddenPath, referenceIds: [b.id], path: path,
                    detail: "reference \(b.id) is bound as \(b.role.rawValue) but claims `\(path)`; "
                        + "a \(b.role.rawValue) reference must not reach identity"))
            } else if !permitted.contains(path) && b.role != .otherExplicit {
                findings.append(Finding(
                    kind: .scopeViolation, referenceIds: [b.id], path: path,
                    detail: "reference \(b.id) is bound as \(b.role.rawValue) but claims `\(path)`, "
                        + "which that role does not govern"))
            }
        }
    }

    // Two references claiming the same path: report which, so the operator can decide rather than
    // discovering later that one silently won.
    var byPath = [String: [ReferenceBinding]]()
    for b in bindings {
        for path in b.appliesTo { byPath[path, default: []].append(b) }
    }
    for (path, claimants) in byPath.sorted(by: { $0.key < $1.key }) where claimants.count > 1 {
        let ids = claimants.map(\.id).sorted()
        let weights = claimants.map { "\($0.id)=\($0.weightPPM)ppm" }.sorted().joined(separator: ", ")
        findings.append(Finding(
            kind: .overlappingAuthority, referenceIds: ids, path: path,
            detail: "\(ids.count) references claim `\(path)` (\(weights)); the heavier will dominate, "
                + "which is a decision to make deliberately rather than discover"))
    }

    return AnalysisResult(findings: findings, bindingsChecked: bindings.count)
}

func bindingsFromJson(_ v: Json) -> [ReferenceBinding] {
    guard case .array(let items) = v else { return [] }
    return items.compactMap { item in
        guard let id = item["reference_id"]?.asString,
              let roleName = item["role"]?.asString,
              let role = ReferenceRole(rawValue: roleName) else { return nil }
        var paths = [String]()
        if case .array(let arr)? = item["applies_to"] {
            paths = arr.compactMap { $0.asString }
        }
        return ReferenceBinding(
            id: id,
            role: role,
            roleDetail: item["role_detail"]?.asString,
            weightPPM: item["weight_ppm"]?.asInt ?? 0,
            appliesTo: paths,
            rationale: item["rationale"]?.asString ?? "")
    }
}

func resultToJson(_ r: AnalysisResult) -> Json {
    let findings: [Json] = r.findings.map { f in
        var m: [String: Json] = [
            "kind": .string(f.kind.rawValue),
            "reference_ids": .array(f.referenceIds.map { .string($0) }),
            "detail": .string(f.detail),
        ]
        m["path"] = f.path.map { Json.string($0) } ?? .null
        return .object(m)
    }
    return .object([
        "admissible": .bool(r.admissible),
        "bindings_checked": .int(Int64(r.bindingsChecked)),
        "findings": .array(findings),
    ])
}
