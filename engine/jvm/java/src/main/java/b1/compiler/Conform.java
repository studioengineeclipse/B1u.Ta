package b1.compiler;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;

/**
 * Java conformance entrypoint (SPEC/20-b1-canon-1.md §5).
 *
 * <pre>
 *   stdin  : a JSON document
 *   stdout : 64 lowercase hex digits + newline
 *   stderr : a B1_ERR_* token when the document is rejected
 * </pre>
 */
public final class Conform {

    public static void main(String[] args) throws IOException {
        byte[] raw;
        try (InputStream in = System.in) {
            raw = in.readAllBytes();
        }

        // Decoding must be strict. The default decoder substitutes U+FFFD for malformed input,
        // which would silently change the document and therefore its digest.
        String text;
        try {
            CharBuffer decoded = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(raw));
            text = decoded.toString();
        } catch (CharacterCodingException e) {
            System.err.println("B1_ERR_INVALID_UTF8");
            System.exit(2);
            return;
        }

        try {
            System.out.println(Canon.digestText(text));
        } catch (Canon.B1Exception e) {
            System.err.println(e.token);
            System.exit(2);
        }
    }
}
