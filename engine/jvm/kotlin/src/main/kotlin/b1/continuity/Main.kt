package b1.continuity

import b1.compiler.Canon
import b1.compiler.Canon.JObj

/**
 * Kotlin entrypoint.
 *
 *   conform         read a JSON document on stdin, emit its B1-CANON-1 digest (SPEC/20 §5)
 *   compatibility   read {terminal, next} on stdin, emit a CompatibilityResult
 *   selftest        run the continuity engine's own checks
 *
 * The digest comes from `b1.compiler.Canon` over IF-4, so this confirms the JVM boundary works
 * rather than offering an independent implementation. The manifest records that as `via_jvm`.
 */
fun main(args: Array<String>) {
    when (args.firstOrNull() ?: "conform") {
        "conform" -> {
            val text = System.`in`.readBytes().toString(Charsets.UTF_8)
            try {
                println(Canon.digestText(text))
            } catch (e: Canon.B1Exception) {
                System.err.println(e.token)
                kotlin.system.exitProcess(2)
            }
        }

        "compatibility" -> {
            val text = System.`in`.readBytes().toString(Charsets.UTF_8)
            try {
                val root = Canon.parse(text) as? JObj
                    ?: throw Canon.B1Exception("B1_ERR_PARSE", "expected an object")
                val terminal = root.get("terminal") as? JObj
                    ?: throw Canon.B1Exception("B1_ERR_PARSE", "missing `terminal`")
                val next = root.get("next") as? JObj
                    ?: throw Canon.B1Exception("B1_ERR_PARSE", "missing `next`")
                val result = checkCompatibility(jsonToBoundary(terminal), jsonToBoundary(next))
                println(Canon.canonicalize(compatibilityToJson(result)))
            } catch (e: Canon.B1Exception) {
                System.err.println(e.token)
                kotlin.system.exitProcess(2)
            }
        }

        "selftest" -> kotlin.system.exitProcess(selfTest())

        else -> {
            System.err.println("usage: b1continuity [conform|compatibility|selftest]")
            kotlin.system.exitProcess(2)
        }
    }
}
