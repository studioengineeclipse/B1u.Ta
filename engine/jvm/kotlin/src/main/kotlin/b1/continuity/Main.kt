package b1.continuity

import b1.compiler.Canon
import b1.compiler.Canon.JObj
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * Reads stdin as UTF-8, refusing malformed bytes rather than replacing them.
 *
 * `readBytes().toString(Charsets.UTF_8)` substitutes U+FFFD for every malformed byte, so the invalid
 * input vanished before any check could see it: `{"a":"\xff"}` and `{"a":"\xfe"}` — two different
 * documents — were both accepted here and given the same digest, while eleven implementations
 * rejected both.
 *
 * `Conform.java`, which this file calls into over IF-4, has always decoded strictly. The boundary
 * was the leak: reaching a correct implementation through a lossy entrypoint gives a wrong answer
 * just as surely as a wrong implementation does.
 */
private fun readStdinStrictUtf8(): String {
    val raw = System.`in`.readBytes()
    return try {
        StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(raw))
            .toString()
    } catch (e: CharacterCodingException) {
        System.err.println("B1_ERR_INVALID_UTF8")
        kotlin.system.exitProcess(2)
    }
}

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
            val text = readStdinStrictUtf8()
            try {
                println(Canon.digestText(text))
            } catch (e: Canon.B1Exception) {
                System.err.println(e.token)
                kotlin.system.exitProcess(2)
            }
        }

        "compatibility" -> {
            val text = readStdinStrictUtf8()
            try {
                val root = Canon.parse(text) as? JObj
                    ?: throw Canon.B1Exception("B1_ERR_PARSE", "expected an object")
                val terminal = root.get("terminal") as? JObj
                    ?: throw Canon.B1Exception("B1_ERR_PARSE", "missing `terminal`")
                val next = root.get("next") as? JObj
                    ?: throw Canon.B1Exception("B1_ERR_PARSE", "missing `next`")
                val result = checkCompatibility(jsonToBoundary(terminal), jsonToBoundary(next))
                println(Canon.canonicalize(compatibilityToJson(result)))
                // 4 = a negative verdict, matching the authority gate and the quality engine. An
                // incompatible boundary is the engine working, not failing, so it must be
                // distinguishable from a crash — and uniform across components, or nothing can
                // branch on a verdict without knowing which component produced it.
                if (!result.compatible) kotlin.system.exitProcess(4)
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
