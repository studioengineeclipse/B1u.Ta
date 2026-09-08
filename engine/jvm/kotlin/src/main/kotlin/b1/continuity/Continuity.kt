package b1.continuity

import b1.compiler.Canon
import b1.compiler.Canon.JArr
import b1.compiler.Canon.JBool
import b1.compiler.Canon.JInt
import b1.compiler.Canon.JObj
import b1.compiler.Canon.JStr
import b1.compiler.Canon.Json

/**
 * The Kagenashi chained continuity engine. Normative: SPEC/60-continuity.md.
 *
 * Kotlin owns this because the continuation priority order is a lattice, and sealed hierarchies
 * make it *total*: every source is one of exactly six cases and every `when` over them is checked
 * for exhaustiveness at compile time. A newly added source type cannot silently fall through to
 * "no opinion" — the compiler refuses the code until the new case is handled.
 *
 * Canonicalization comes from `b1.compiler.Canon` over IF-4 rather than being reimplemented here.
 * Java and Kotlin share a runtime, so a second codec would be a duplicate implementation in a
 * language that can call the original directly.
 */

/**
 * Sources that can influence a continuation, in priority order.
 *
 * The ordering encodes the law: a verified previous clip is hard temporal history, and a new
 * reference is soft future influence. Note that the user's own continuation instruction sits
 * *below* the verified clip and its terminal state. That is deliberate — observed, accepted history
 * is not overridden by a new instruction unless the user explicitly asks for a revision, at which
 * point the request is a revision rather than a continuation.
 */
sealed class ContinuationSource(val priority: Int, val label: String) {
    object VerifiedPreviousClip : ContinuationSource(1, "P1_VERIFIED_PREVIOUS_CLIP")
    object TerminalContinuityState : ContinuationSource(2, "P2_TERMINAL_CONTINUITY_STATE")
    object UserContinuationInstruction : ContinuationSource(3, "P3_USER_CONTINUATION_INSTRUCTION")
    object NewReferenceMedia : ContinuationSource(4, "P4_NEW_REFERENCE_MEDIA")
    object StyleGuidance : ContinuationSource(5, "P5_STYLE_GUIDANCE")
    object SystemInferred : ContinuationSource(6, "P6_SYSTEM_INFERRED")

    companion object {
        /**
         * Deferred on purpose. The nested singletons are subclasses of this class, so initializing
         * them triggers this companion's initializer and vice versa; an eagerly-built list is
         * populated during that cycle and ends up holding nulls. `by lazy` defers construction to
         * first access, by which point every singleton exists. The self-test caught this as an NPE
         * rather than it surfacing later as a silently empty lattice.
         */
        val all: List<ContinuationSource> by lazy {
            listOf(
                VerifiedPreviousClip, TerminalContinuityState, UserContinuationInstruction,
                NewReferenceMedia, StyleGuidance, SystemInferred,
            )
        }

        fun parse(label: String): ContinuationSource? = all.firstOrNull { it.label == label }
    }
}

/** A claim by one source about one field. */
data class Claim(
    val source: ContinuationSource,
    val field: String,
    val value: String,
)

data class ContinuationConflict(
    val higher: ContinuationSource,
    val lower: ContinuationSource,
    val contestedField: String,
    val winning: String,
    val suppressed: String,
    val userOverride: Boolean,
)

data class Resolution(
    val resolved: Map<String, String>,
    val conflicts: List<ContinuationConflict>,
)

/**
 * Resolves competing claims. A lower-priority source may not contradict a higher-priority one
 * without explicit user authorization; where it tries, the higher wins and the suppression is
 * recorded rather than discarded — a silently dropped claim is indistinguishable from one that was
 * never made.
 */
fun resolve(claims: List<Claim>, userOverriddenFields: Set<String> = emptySet()): Resolution {
    val byField = claims.groupBy { it.field }
    val resolved = mutableMapOf<String, String>()
    val conflicts = mutableListOf<ContinuationConflict>()

    for ((field, fieldClaims) in byField) {
        val ordered = fieldClaims.sortedBy { it.source.priority }
        val winner = ordered.first()
        resolved[field] = winner.value

        for (loser in ordered.drop(1)) {
            if (loser.value == winner.value) continue // agreement is not a conflict
            conflicts += ContinuationConflict(
                higher = winner.source,
                lower = loser.source,
                contestedField = field,
                winning = winner.value,
                suppressed = loser.value,
                userOverride = field in userOverriddenFields,
            )
        }
    }
    return Resolution(resolved, conflicts)
}

// --- causal compatibility -----------------------------------------------------

enum class Predicate {
    POSITIONAL_DRIFT,
    VELOCITY_CONTINUITY,
    CONTACT_STATE,
    CARRIED_OBJECTS,
    CAMERA_CONTINUITY,
    LIGHTING_CONTINUITY,
    VISUAL_SIGNATURE_DISTANCE,
}

data class Violation(
    val predicate: Predicate,
    val detail: String,
    val measured: Long?,
    val tolerance: Long,
)

data class CompatibilityResult(
    val compatible: Boolean,
    val violations: List<Violation>,
)

/** Tolerances in integer units, per SPEC/60 §3. */
data class Tolerances(
    val positionMm: Long = 300,
    val velocityMmPerS: Long = 400,
    val cameraPositionMm: Long = 400,
    val cameraVelocityMmPerS: Long = 500,
    val signatureDistanceMu: Long = 250,
)

/**
 * A minimal view of the terminal state of one segment and the opening state of the next. Only the
 * fields the compatibility predicates actually consult are modelled; the full ContinuityState is
 * carried in the contract.
 */
data class BoundaryState(
    val subjectPositionsMm: Map<String, Long>,
    val subjectVelocitiesMmPerS: Map<String, Long>,
    val contactStates: Map<String, String>,
    val carriedObjects: Map<String, Set<String>>,
    val cameraPositionMm: Long,
    val cameraVelocityMmPerS: Long,
    val lightingState: String,
    val visualSignatureDistanceMu: Long?,
    val depictedReleases: Set<String> = emptySet(),
    val justifiedCut: Boolean = false,
    val justifiedLightingTransition: Boolean = false,
)

/**
 * Checks whether the first frame of the next generation is causally compatible with the previous
 * terminal state.
 *
 * Each violation names the predicate it broke. "Continuity failed" is not actionable; "the subject
 * teleported 2.1 m" tells the repair what to fix.
 */
fun checkCompatibility(
    terminal: BoundaryState,
    next: BoundaryState,
    tol: Tolerances = Tolerances(),
): CompatibilityResult {
    val violations = mutableListOf<Violation>()

    for ((subject, terminalPos) in terminal.subjectPositionsMm) {
        val nextPos = next.subjectPositionsMm[subject] ?: continue
        val drift = Math.abs(nextPos - terminalPos)
        if (drift > tol.positionMm) {
            violations += Violation(
                Predicate.POSITIONAL_DRIFT,
                "$subject moved ${drift}mm across the segment boundary, which no depicted motion accounts for",
                drift, tol.positionMm,
            )
        }
    }

    for ((subject, terminalVel) in terminal.subjectVelocitiesMmPerS) {
        val nextVel = next.subjectVelocitiesMmPerS[subject] ?: continue
        val delta = Math.abs(nextVel - terminalVel)
        if (delta > tol.velocityMmPerS) {
            val stopped = terminalVel != 0L && nextVel == 0L
            violations += Violation(
                Predicate.VELOCITY_CONTINUITY,
                if (stopped) "$subject was moving at ${terminalVel}mm/s and is stationary at the next first frame: an unexplained stop"
                else "$subject velocity jumped by ${delta}mm/s across the boundary",
                delta, tol.velocityMmPerS,
            )
        }
    }

    for ((subject, terminalContact) in terminal.contactStates) {
        val nextContact = next.contactStates[subject] ?: continue
        if (terminalContact != nextContact) {
            violations += Violation(
                Predicate.CONTACT_STATE,
                "$subject contact changed from $terminalContact to $nextContact with no legal transition event",
                null, 0,
            )
        }
    }

    for ((subject, terminalCarried) in terminal.carriedObjects) {
        val nextCarried = next.carriedObjects[subject] ?: emptySet()
        val dropped = terminalCarried - nextCarried
        // An object may leave the hand — but only through a depicted release, not by vanishing.
        val unexplained = dropped - next.depictedReleases
        if (unexplained.isNotEmpty()) {
            violations += Violation(
                Predicate.CARRIED_OBJECTS,
                "$subject stopped carrying ${unexplained.joinToString(", ")} with no depicted release",
                null, 0,
            )
        }
    }

    if (!next.justifiedCut) {
        val camDrift = Math.abs(next.cameraPositionMm - terminal.cameraPositionMm)
        if (camDrift > tol.cameraPositionMm) {
            violations += Violation(
                Predicate.CAMERA_CONTINUITY,
                "camera jumped ${camDrift}mm with no cut justification",
                camDrift, tol.cameraPositionMm,
            )
        }
        val camVelDelta = Math.abs(next.cameraVelocityMmPerS - terminal.cameraVelocityMmPerS)
        if (camVelDelta > tol.cameraVelocityMmPerS) {
            violations += Violation(
                Predicate.CAMERA_CONTINUITY,
                "camera velocity changed by ${camVelDelta}mm/s across the boundary: the move restarts rather than continuing",
                camVelDelta, tol.cameraVelocityMmPerS,
            )
        }
    }

    if (!next.justifiedLightingTransition && terminal.lightingState != next.lightingState) {
        violations += Violation(
            Predicate.LIGHTING_CONTINUITY,
            "lighting changed from '${terminal.lightingState}' to '${next.lightingState}' with no specified transition",
            null, 0,
        )
    }

    next.visualSignatureDistanceMu?.let { distance ->
        if (distance > tol.signatureDistanceMu) {
            violations += Violation(
                Predicate.VISUAL_SIGNATURE_DISTANCE,
                "frame signature distance $distance exceeds tolerance: the frames are structurally unrelated",
                distance, tol.signatureDistanceMu,
            )
        }
    }

    return CompatibilityResult(violations.isEmpty(), violations)
}

// --- extension-safe endings ---------------------------------------------------

enum class EndingPattern(val label: String) {
    ARBITRARY_FREEZE("arbitrary_freeze"),
    CELEBRATION("celebration"),
    POSE("pose"),
    FADE_OUT("fade_out"),
    HARD_STOP("hard_stop"),
    UNEXPLAINED_CAMERA_HALT("unexplained_camera_halt"),
    ARTIFICIAL_RESET("artificial_reset"),
    NEUTRAL_OBJECT_RESET("neutral_object_reset"),
}

data class EndingVerdict(
    val extendable: Boolean,
    val detected: List<EndingPattern>,
    val reason: String,
)

/**
 * Validates that a segment ends in a state the next one can continue from.
 *
 * The rationale is mechanical rather than aesthetic: a clip that ends in a freeze, a settled pose,
 * a fade, or with objects reset to neutral positions has destroyed the state the next segment needs
 * to inherit. `unresolvedMotion` must be non-empty for an extendable ending — that is precisely the
 * state being handed forward.
 */
fun validateEnding(
    mustBeExtendable: Boolean,
    unresolvedMotion: List<String>,
    terminalSubjectVelocities: Map<String, Long>,
    terminalCameraVelocityMmPerS: Long,
    cameraMoveWasActive: Boolean,
    fadeDetected: Boolean,
    objectsAtNeutral: Boolean,
): EndingVerdict {
    if (!mustBeExtendable) {
        return EndingVerdict(true, emptyList(), "the user asked for the event to conclude within the take")
    }

    val detected = mutableListOf<EndingPattern>()

    if (terminalSubjectVelocities.isNotEmpty() && terminalSubjectVelocities.values.all { it == 0L }) {
        detected += EndingPattern.ARBITRARY_FREEZE
    }
    if (cameraMoveWasActive && terminalCameraVelocityMmPerS == 0L) {
        detected += EndingPattern.UNEXPLAINED_CAMERA_HALT
    }
    if (fadeDetected) detected += EndingPattern.FADE_OUT
    if (objectsAtNeutral) detected += EndingPattern.NEUTRAL_OBJECT_RESET

    if (unresolvedMotion.isEmpty()) {
        detected += EndingPattern.HARD_STOP
    }

    val reason = if (detected.isEmpty()) {
        "motion is still in progress at the final frame and ${unresolvedMotion.size} thread(s) remain unresolved"
    } else {
        "the take forecloses continuation: " + detected.joinToString(", ") { it.label }
    }
    return EndingVerdict(detected.isEmpty(), detected, reason)
}

// --- JSON bridge --------------------------------------------------------------

internal fun jsonToBoundary(o: JObj): BoundaryState {
    fun longMap(key: String): Map<String, Long> {
        val node = o.get(key) as? JObj ?: return emptyMap()
        return node.members().entries.associate { (k, v) -> k to ((v as? JInt)?.value() ?: 0L) }
    }

    fun strMap(key: String): Map<String, String> {
        val node = o.get(key) as? JObj ?: return emptyMap()
        return node.members().entries.associate { (k, v) -> k to ((v as? JStr)?.value() ?: "") }
    }

    fun setMap(key: String): Map<String, Set<String>> {
        val node = o.get(key) as? JObj ?: return emptyMap()
        return node.members().entries.associate { (k, v) ->
            k to ((v as? JArr)?.items()?.mapNotNull { (it as? JStr)?.value() }?.toSet() ?: emptySet())
        }
    }

    fun strSet(key: String): Set<String> =
        (o.get(key) as? JArr)?.items()?.mapNotNull { (it as? JStr)?.value() }?.toSet() ?: emptySet()

    fun long(key: String, fallback: Long = 0L): Long = (o.get(key) as? JInt)?.value() ?: fallback
    fun str(key: String): String = (o.get(key) as? JStr)?.value() ?: ""
    fun bool(key: String): Boolean = (o.get(key) as? JBool)?.value() ?: false

    return BoundaryState(
        subjectPositionsMm = longMap("subject_positions_mm"),
        subjectVelocitiesMmPerS = longMap("subject_velocities_mm_per_s"),
        contactStates = strMap("contact_states"),
        carriedObjects = setMap("carried_objects"),
        cameraPositionMm = long("camera_position_mm"),
        cameraVelocityMmPerS = long("camera_velocity_mm_per_s"),
        lightingState = str("lighting_state"),
        visualSignatureDistanceMu = (o.get("visual_signature_distance_mu") as? JInt)?.value(),
        depictedReleases = strSet("depicted_releases"),
        justifiedCut = bool("justified_cut"),
        justifiedLightingTransition = bool("justified_lighting_transition"),
    )
}

internal fun compatibilityToJson(r: CompatibilityResult): JObj {
    val out = Canon.obj()
    Canon.put(out, "compatible", JBool(r.compatible))
    val arr = r.violations.map { v ->
        val item = Canon.obj()
        Canon.put(item, "predicate", JStr(v.predicate.name))
        Canon.put(item, "detail", JStr(v.detail))
        Canon.put(item, "measured", if (v.measured == null) Canon.JNull() else JInt(v.measured))
        Canon.put(item, "tolerance", JInt(v.tolerance))
        item as Json
    }
    Canon.put(out, "violations", JArr(arr))
    return out
}
