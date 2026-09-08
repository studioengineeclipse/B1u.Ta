package b1.continuity

/**
 * The continuity engine's own checks — success criterion S6: continuity is causal, not decorative.
 *
 * Written as a self-contained runner rather than a test framework so it runs from the same jar the
 * conformance harness already builds, with no additional dependency to install offline.
 */

private var failures = 0

private fun ok(what: String) = println("  ok    $what")

private fun bad(what: String, detail: String = "") {
    println("  FAIL  $what${if (detail.isEmpty()) "" else "\n        $detail"}")
    failures++
}

private fun check(what: String, condition: Boolean, detail: String = "") {
    if (condition) ok(what) else bad(what, detail)
}

private fun boundary(
    positions: Map<String, Long> = mapOf("kage" to 0L),
    velocities: Map<String, Long> = mapOf("kage" to 1400L),
    contacts: Map<String, String> = mapOf("kage" to "left_foot_down"),
    carried: Map<String, Set<String>> = mapOf("kage" to setOf("satchel")),
    cameraPos: Long = 0L,
    cameraVel: Long = 1400L,
    lighting: String = "strip_lights_overhead",
    signature: Long? = 40L,
    releases: Set<String> = emptySet(),
    justifiedCut: Boolean = false,
    justifiedLighting: Boolean = false,
) = BoundaryState(positions, velocities, contacts, carried, cameraPos, cameraVel, lighting,
    signature, releases, justifiedCut, justifiedLighting)

fun selfTest(): Int {
    failures = 0

    println("continuation priority lattice")
    run {
        // A new reference and the verified previous clip disagree about the gait phase.
        val claims = listOf(
            Claim(ContinuationSource.NewReferenceMedia, "gait_phase", "right_foot_down"),
            Claim(ContinuationSource.VerifiedPreviousClip, "gait_phase", "left_foot_down"),
            Claim(ContinuationSource.StyleGuidance, "grade", "cool"),
        )
        val r = resolve(claims)
        check("verified history outranks a new reference",
            r.resolved["gait_phase"] == "left_foot_down",
            "resolved to ${r.resolved["gait_phase"]}")
        check("the suppressed claim is recorded, not discarded",
            r.conflicts.size == 1 && r.conflicts[0].suppressed == "right_foot_down")
        check("an uncontested claim survives", r.resolved["grade"] == "cool")
    }

    run {
        // The user's continuation instruction sits below verified history — SPEC/60 §4.
        val claims = listOf(
            Claim(ContinuationSource.UserContinuationInstruction, "gait_phase", "right_foot_down"),
            Claim(ContinuationSource.TerminalContinuityState, "gait_phase", "left_foot_down"),
        )
        val r = resolve(claims)
        check("terminal state outranks a new continuation instruction",
            r.resolved["gait_phase"] == "left_foot_down",
            "a new instruction does not silently rewrite observed history; a revision is a different request")
    }

    run {
        val r = resolve(listOf(
            Claim(ContinuationSource.VerifiedPreviousClip, "f", "same"),
            Claim(ContinuationSource.SystemInferred, "f", "same"),
        ))
        check("agreement is not recorded as a conflict", r.conflicts.isEmpty())
    }

    check("the lattice covers exactly six sources", ContinuationSource.all.size == 6)
    check("priorities are 1..6 with no gaps",
        ContinuationSource.all.map { it.priority }.sorted() == (1..6).toList())

    println("causal compatibility")
    run {
        val r = checkCompatibility(boundary(), boundary())
        check("an unchanged boundary is compatible", r.compatible, r.violations.toString())
    }

    run {
        // The subject is walking, then stationary: the classic unexplained stop.
        val r = checkCompatibility(boundary(), boundary(velocities = mapOf("kage" to 0L)))
        check("an unexplained stop is caught", !r.compatible)
        check("it is named as a velocity discontinuity",
            r.violations.any { it.predicate == Predicate.VELOCITY_CONTINUITY })
        check("the violation says what happened, not merely that something did",
            r.violations.any { it.detail.contains("unexplained stop") },
            r.violations.joinToString { it.detail })
    }

    run {
        val r = checkCompatibility(boundary(), boundary(positions = mapOf("kage" to 2100L)))
        check("a teleport is caught", !r.compatible)
        check("it reports the measured drift and the tolerance",
            r.violations.any { it.predicate == Predicate.POSITIONAL_DRIFT && it.measured == 2100L && it.tolerance == 300L })
    }

    run {
        val r = checkCompatibility(boundary(), boundary(carried = mapOf("kage" to emptySet())))
        check("an object vanishing from the hand is caught", !r.compatible)
        check("it is named as a carried-object violation",
            r.violations.any { it.predicate == Predicate.CARRIED_OBJECTS })
    }

    run {
        // The same disappearance, but the release is depicted: legal.
        val r = checkCompatibility(
            boundary(),
            boundary(carried = mapOf("kage" to emptySet()), releases = setOf("satchel")),
        )
        check("a depicted release is legal", r.compatible, r.violations.joinToString { it.detail })
    }

    run {
        val jump = checkCompatibility(boundary(), boundary(cameraPos = 5000L))
        check("an unjustified camera jump is caught", !jump.compatible)
        val cut = checkCompatibility(boundary(), boundary(cameraPos = 5000L, justifiedCut = true))
        check("the same jump is legal when the cut is justified", cut.compatible)
    }

    run {
        val drift = checkCompatibility(boundary(), boundary(lighting = "daylight"))
        check("unexplained lighting change is caught", !drift.compatible)
        val transition = checkCompatibility(boundary(), boundary(lighting = "daylight", justifiedLighting = true))
        check("a specified lighting transition is legal", transition.compatible)
    }

    run {
        val r = checkCompatibility(boundary(), boundary(signature = 800L))
        check("structurally unrelated frames are caught",
            r.violations.any { it.predicate == Predicate.VISUAL_SIGNATURE_DISTANCE })
    }

    run {
        // Several independent breaks at once: each must be reported, not just the first.
        val r = checkCompatibility(
            boundary(),
            boundary(positions = mapOf("kage" to 9000L), velocities = mapOf("kage" to 0L), lighting = "daylight"),
        )
        check("every violated predicate is reported", r.violations.size >= 3,
            "got ${r.violations.size}: ${r.violations.map { it.predicate }}")
    }

    println("extension-safe endings")
    run {
        val v = validateEnding(
            mustBeExtendable = true,
            unresolvedMotion = listOf("still walking", "package undelivered"),
            terminalSubjectVelocities = mapOf("kage" to 1400L),
            terminalCameraVelocityMmPerS = 1400L,
            cameraMoveWasActive = true,
            fadeDetected = false,
            objectsAtNeutral = false,
        )
        check("mid-motion ending is extendable", v.extendable, v.reason)
    }

    run {
        val v = validateEnding(true, listOf("still walking"), mapOf("kage" to 0L), 0L, true, false, false)
        check("a freeze is rejected", !v.extendable)
        check("both the freeze and the camera halt are named",
            v.detected.containsAll(listOf(EndingPattern.ARBITRARY_FREEZE, EndingPattern.UNEXPLAINED_CAMERA_HALT)),
            v.detected.toString())
    }

    run {
        val v = validateEnding(true, emptyList(), mapOf("kage" to 1400L), 1400L, true, false, false)
        check("no unresolved motion is a hard stop",
            !v.extendable && v.detected.contains(EndingPattern.HARD_STOP),
            "an ending with nothing left unresolved leaves the next segment nothing to inherit")
    }

    run {
        val v = validateEnding(true, listOf("walking"), mapOf("kage" to 1400L), 1400L, true, true, true)
        check("a fade and a neutral reset are both caught",
            v.detected.containsAll(listOf(EndingPattern.FADE_OUT, EndingPattern.NEUTRAL_OBJECT_RESET)))
    }

    run {
        val v = validateEnding(false, emptyList(), mapOf("kage" to 0L), 0L, true, true, true)
        check("an explicitly concluding take is allowed to conclude", v.extendable, v.reason)
    }

    println()
    println(if (failures == 0) "PASSED: 0 failures" else "FAILED: $failures failure(s)")
    return if (failures == 0) 0 else 1
}
