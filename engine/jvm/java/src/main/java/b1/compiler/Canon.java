package b1.compiler;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * B1-CANON-1: strict parsing, canonical serialization and digest.
 * Normative definition: SPEC/20-b1-canon-1.md. Normative implementation: core/c/libb1sig.
 *
 * <p>The JDK ships no JSON parser, so one is written here regardless. That turns out to suit the
 * profile: its guarantees are mostly rejections — duplicate member names, non-integer numbers,
 * non-ASCII keys and unpaired surrogates must all fail loudly — and a permissive parser that
 * silently repaired any of them would produce a digest no other implementation reproduces.
 */
public final class Canon {

    public static final int MAX_DEPTH = 64;
    public static final long MAX_SAFE = 9007199254740991L; // 2^53 - 1
    public static final String ZERO_LINK = "b1c1:" + "0".repeat(64);

    private Canon() {}

    /** Carries a stable B1_ERR_* token, which is what the conform protocol prints. */
    public static class B1Exception extends RuntimeException {
        public final String token;

        public B1Exception(String token, String detail) {
            super(token + ": " + detail);
            this.token = token;
        }
    }

    // --- value model ---------------------------------------------------------
    //
    // There is deliberately no floating-point variant: R1 forbids non-integer numbers, so a
    // document the profile could not canonicalize cannot be represented in the first place.

    public sealed interface Json
            permits JNull, JBool, JInt, JStr, JArr, JObj {}

    public record JNull() implements Json {}

    public record JBool(boolean value) implements Json {}

    public record JInt(long value) implements Json {}

    public record JStr(String value) implements Json {}

    public record JArr(List<Json> items) implements Json {}

    /** TreeMap keeps members in sorted order, which for ASCII-only names (R2) is canonical order. */
    public record JObj(TreeMap<String, Json> members) implements Json {
        public Json get(String key) {
            return members.get(key);
        }
    }

    public static JObj obj() {
        return new JObj(new TreeMap<>());
    }

    public static JObj put(JObj o, String key, Json value) {
        o.members().put(key, value);
        return o;
    }

    public static boolean keySyntaxOk(String k) {
        int n = k.length();
        if (n < 1 || n > 64) return false;
        for (int i = 0; i < n; i++) {
            char c = k.charAt(i);
            boolean ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || c == '_' || c == '$' || c == '.' || c == '-';
            if (!ok) return false;
        }
        return true;
    }

    // --- parser --------------------------------------------------------------

    private static final class Parser {
        private final String s;
        private int i;

        Parser(String s) {
            this.s = s;
        }

        void ws() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++;
                else return;
            }
        }

        void lit(String word) {
            if (s.startsWith(word, i)) i += word.length();
            else throw new B1Exception("B1_ERR_PARSE", "expected " + word + " at " + i);
        }

        Json value(int depth) {
            if (depth > MAX_DEPTH) throw new B1Exception("B1_ERR_DEPTH", "depth > " + MAX_DEPTH);
            if (i >= s.length()) throw new B1Exception("B1_ERR_PARSE", "unexpected end of input");
            char c = s.charAt(i);
            if (c == '{') return object(depth);
            if (c == '[') return array(depth);
            if (c == '"') return new JStr(str());
            if (c == 't') { lit("true"); return new JBool(true); }
            if (c == 'f') { lit("false"); return new JBool(false); }
            if (c == 'n') { lit("null"); return new JNull(); }
            if (c == '-' || (c >= '0' && c <= '9')) return new JInt(number());
            throw new B1Exception("B1_ERR_PARSE", "unexpected character at " + i);
        }

        Json object(int depth) {
            i++;
            TreeMap<String, Json> map = new TreeMap<>();
            ws();
            if (i < s.length() && s.charAt(i) == '}') { i++; return new JObj(map); }
            while (true) {
                ws();
                if (i >= s.length() || s.charAt(i) != '"')
                    throw new B1Exception("B1_ERR_PARSE", "expected key at " + i);
                String key = str();
                if (!keySyntaxOk(key)) throw new B1Exception("B1_ERR_KEY_SYNTAX", key);
                if (map.containsKey(key)) throw new B1Exception("B1_ERR_DUPLICATE_KEY", key);
                ws();
                if (i >= s.length() || s.charAt(i) != ':')
                    throw new B1Exception("B1_ERR_PARSE", "expected ':' at " + i);
                i++;
                ws();
                map.put(key, value(depth + 1));
                ws();
                if (i >= s.length()) throw new B1Exception("B1_ERR_PARSE", "unterminated object");
                char c = s.charAt(i);
                if (c == ',') { i++; continue; }
                if (c == '}') { i++; return new JObj(map); }
                throw new B1Exception("B1_ERR_PARSE", "expected ',' or '}' at " + i);
            }
        }

        Json array(int depth) {
            i++;
            List<Json> out = new ArrayList<>();
            ws();
            if (i < s.length() && s.charAt(i) == ']') { i++; return new JArr(out); }
            while (true) {
                ws();
                out.add(value(depth + 1));
                ws();
                if (i >= s.length()) throw new B1Exception("B1_ERR_PARSE", "unterminated array");
                char c = s.charAt(i);
                if (c == ',') { i++; continue; }
                if (c == ']') { i++; return new JArr(out); }
                throw new B1Exception("B1_ERR_PARSE", "expected ',' or ']' at " + i);
            }
        }

        long number() {
            int start = i;
            if (s.charAt(i) == '-') i++;
            int digitsStart = i;
            while (i < s.length() && s.charAt(i) >= '0' && s.charAt(i) <= '9') i++;
            if (i == digitsStart) throw new B1Exception("B1_ERR_PARSE", "expected digits at " + start);
            if (i - digitsStart > 1 && s.charAt(digitsStart) == '0')
                throw new B1Exception("B1_ERR_PARSE", "leading zero at " + digitsStart);
            if (i < s.length()) {
                char c = s.charAt(i);
                if (c == '.' || c == 'e' || c == 'E')
                    throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "at " + start);
            }
            String text = s.substring(start, i);
            if (text.equals("-0")) throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "negative zero");
            long v;
            try {
                v = Long.parseLong(text);
            } catch (NumberFormatException e) {
                throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "out of range: " + text);
            }
            if (v > MAX_SAFE || v < -MAX_SAFE)
                throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "out of range: " + text);
            return v;
        }

        int hex4() {
            if (i + 4 > s.length()) throw new B1Exception("B1_ERR_PARSE", "truncated \\u escape");
            int v = 0;
            for (int k = 0; k < 4; k++) {
                char c = s.charAt(i + k);
                v <<= 4;
                if (c >= '0' && c <= '9') v |= c - '0';
                else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
                else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
                else throw new B1Exception("B1_ERR_PARSE", "bad \\u escape at " + i);
            }
            i += 4;
            return v;
        }

        /**
         * Decodes one {@code \\uXXXX}, joining a surrogate pair into a single scalar. Java strings
         * are UTF-16, so an unpaired half would survive here and only fail later — it is rejected
         * at the point it is read instead.
         */
        void unicodeEscape(StringBuilder out) {
            int cp = hex4();
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                if (i + 2 > s.length() || s.charAt(i) != '\\' || s.charAt(i + 1) != 'u')
                    throw new B1Exception("B1_ERR_INVALID_UTF8", "unpaired high surrogate");
                i += 2;
                int low = hex4();
                if (low < 0xDC00 || low > 0xDFFF)
                    throw new B1Exception("B1_ERR_INVALID_UTF8", "high surrogate not followed by a low one");
                out.appendCodePoint(0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00));
                return;
            }
            if (cp >= 0xDC00 && cp <= 0xDFFF)
                throw new B1Exception("B1_ERR_INVALID_UTF8", "unpaired low surrogate");
            out.appendCodePoint(cp);
        }

        String str() {
            i++; // opening quote
            StringBuilder out = new StringBuilder();
            while (true) {
                if (i >= s.length()) throw new B1Exception("B1_ERR_PARSE", "unterminated string");
                char c = s.charAt(i);
                if (c == '"') { i++; return out.toString(); }
                if (c == '\\') {
                    i++;
                    if (i >= s.length()) throw new B1Exception("B1_ERR_PARSE", "unterminated escape");
                    char e = s.charAt(i);
                    i++;
                    switch (e) {
                        case '"' -> out.append('"');
                        case '\\' -> out.append('\\');
                        case '/' -> out.append('/');
                        case 'b' -> out.append('\b');
                        case 'f' -> out.append('\f');
                        case 'n' -> out.append('\n');
                        case 'r' -> out.append('\r');
                        case 't' -> out.append('\t');
                        case 'u' -> unicodeEscape(out);
                        default -> throw new B1Exception("B1_ERR_PARSE", "bad escape \\" + e);
                    }
                    continue;
                }
                if (c < 0x20) throw new B1Exception("B1_ERR_PARSE", "raw control char at " + i);
                out.append(c);
                i++;
            }
        }
    }

    public static Json parse(String text) {
        Parser p = new Parser(text);
        p.ws();
        Json v = p.value(0);
        p.ws();
        if (p.i != text.length()) throw new B1Exception("B1_ERR_PARSE", "trailing input");
        return v;
    }

    // --- serialization -------------------------------------------------------

    private static void escapeInto(StringBuilder out, String s) {
        out.append('"');
        for (int i = 0; i < s.length(); ) {
            int cp = s.codePointAt(i);
            i += Character.charCount(cp);
            switch (cp) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\b' -> out.append("\\b");
                case '\t' -> out.append("\\t");
                case '\n' -> out.append("\\n");
                case '\f' -> out.append("\\f");
                case '\r' -> out.append("\\r");
                default -> {
                    if (cp < 0x20) out.append(String.format("\\u%04x", cp)); // lowercase, per R3
                    else out.appendCodePoint(cp);
                }
            }
        }
        out.append('"');
    }

    private static void canonInto(StringBuilder out, Json v, int depth) {
        if (depth > MAX_DEPTH) throw new B1Exception("B1_ERR_DEPTH", "depth > " + MAX_DEPTH);
        switch (v) {
            case JNull ignored -> out.append("null");
            case JBool b -> out.append(b.value() ? "true" : "false");
            case JInt n -> {
                if (n.value() > MAX_SAFE || n.value() < -MAX_SAFE)
                    throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "out of range");
                out.append(n.value());
            }
            case JStr s -> escapeInto(out, s.value());
            case JArr a -> {
                out.append('[');
                boolean first = true;
                for (Json item : a.items()) {
                    if (!first) out.append(',');
                    first = false;
                    canonInto(out, item, depth + 1);
                }
                out.append(']');
            }
            case JObj o -> {
                out.append('{');
                boolean first = true;
                for (Map.Entry<String, Json> e : o.members().entrySet()) {
                    if (!keySyntaxOk(e.getKey())) throw new B1Exception("B1_ERR_KEY_SYNTAX", e.getKey());
                    if (!first) out.append(',');
                    first = false;
                    escapeInto(out, e.getKey());
                    out.append(':');
                    canonInto(out, e.getValue(), depth + 1);
                }
                out.append('}');
            }
        }
    }

    public static String canonicalize(Json v) {
        StringBuilder out = new StringBuilder();
        canonInto(out, v, 0);
        return out.toString();
    }

    public static String digestValue(Json v) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(canonicalize(v).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(64);
            for (byte b : hash) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    public static String digestText(String text) {
        return digestValue(parse(text));
    }

    /** The prefix labels the algorithm and is not part of the hashed input. */
    public static String b1c1(String digestHex) {
        return "b1c1:" + digestHex;
    }
}
