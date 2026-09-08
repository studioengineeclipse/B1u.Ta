using System.Security.Cryptography;
using System.Text;

namespace B1.Convergence;

/// <summary>
/// B1-CANON-1: strict parsing, canonical serialization and digest.
/// Normative definition: SPEC/20-b1-canon-1.md. Normative implementation: core/c/libb1sig.
/// </summary>
/// <remarks>
/// Written independently rather than bound to the C library, so its agreement with the normative
/// implementation is a genuine cross-check. System.Text.Json is not used: it keeps the last of a
/// set of duplicate member names and is permissive about numbers, and both of those silently repair
/// documents this profile is required to reject.
/// </remarks>
public sealed class B1Exception : Exception
{
    public string Token { get; }

    public B1Exception(string token, string detail) : base($"{token}: {detail}") => Token = token;
}

public abstract record Json
{
    public sealed record Null : Json;

    public sealed record Bool(bool Value) : Json;

    public sealed record Int(long Value) : Json;

    public sealed record Str(string Value) : Json;

    public sealed record Arr(IReadOnlyList<Json> Items) : Json;

    /// <summary>SortedDictionary keeps members in canonical order, which for ASCII-only names (R2)
    /// is byte order — so serialization never has to sort and can never forget to.</summary>
    public sealed record Obj(SortedDictionary<string, Json> Members) : Json
    {
        public Json? Get(string key) => Members.TryGetValue(key, out var v) ? v : null;
    }

    public static Obj NewObj() => new(new SortedDictionary<string, Json>(StringComparer.Ordinal));
}

public static class Canon
{
    public const int MaxDepth = 64;
    public const long MaxSafe = 9007199254740991L; // 2^53 - 1

    public static bool KeySyntaxOk(string k)
    {
        if (k.Length is < 1 or > 64) return false;
        foreach (var c in k)
        {
            var ok = c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9'
                     or '_' or '$' or '.' or '-';
            if (!ok) return false;
        }
        return true;
    }

    private sealed class Parser(string s)
    {
        private int _i;

        public Json Parse()
        {
            SkipWs();
            var v = Value(0);
            SkipWs();
            if (_i != s.Length) throw new B1Exception("B1_ERR_PARSE", "trailing input");
            return v;
        }

        private void SkipWs()
        {
            while (_i < s.Length && (s[_i] == ' ' || s[_i] == '\t' || s[_i] == '\n' || s[_i] == '\r'))
                _i++;
        }

        private void Literal(string word)
        {
            if (_i + word.Length <= s.Length && string.CompareOrdinal(s, _i, word, 0, word.Length) == 0)
                _i += word.Length;
            else throw new B1Exception("B1_ERR_PARSE", $"expected {word} at {_i}");
        }

        private Json Value(int depth)
        {
            if (depth > MaxDepth) throw new B1Exception("B1_ERR_DEPTH", $"depth > {MaxDepth}");
            if (_i >= s.Length) throw new B1Exception("B1_ERR_PARSE", "unexpected end of input");

            var c = s[_i];
            if (c == '{') return Object(depth);
            if (c == '[') return Array(depth);
            if (c == '"') return new Json.Str(String());
            if (c == 't') { Literal("true"); return new Json.Bool(true); }
            if (c == 'f') { Literal("false"); return new Json.Bool(false); }
            if (c == 'n') { Literal("null"); return new Json.Null(); }
            if (c == '-' || c is >= '0' and <= '9') return new Json.Int(Number());
            throw new B1Exception("B1_ERR_PARSE", $"unexpected character at {_i}");
        }

        private Json Object(int depth)
        {
            _i++;
            var map = new SortedDictionary<string, Json>(StringComparer.Ordinal);
            SkipWs();
            if (_i < s.Length && s[_i] == '}') { _i++; return new Json.Obj(map); }

            while (true)
            {
                SkipWs();
                if (_i >= s.Length || s[_i] != '"') throw new B1Exception("B1_ERR_PARSE", "expected key");
                var key = String();
                if (!KeySyntaxOk(key)) throw new B1Exception("B1_ERR_KEY_SYNTAX", key);
                if (map.ContainsKey(key)) throw new B1Exception("B1_ERR_DUPLICATE_KEY", key);
                SkipWs();
                if (_i >= s.Length || s[_i] != ':') throw new B1Exception("B1_ERR_PARSE", "expected ':'");
                _i++;
                SkipWs();
                map[key] = Value(depth + 1);
                SkipWs();
                if (_i >= s.Length) throw new B1Exception("B1_ERR_PARSE", "unterminated object");
                if (s[_i] == ',') { _i++; continue; }
                if (s[_i] == '}') { _i++; return new Json.Obj(map); }
                throw new B1Exception("B1_ERR_PARSE", "expected ',' or '}'");
            }
        }

        private Json Array(int depth)
        {
            _i++;
            var items = new List<Json>();
            SkipWs();
            if (_i < s.Length && s[_i] == ']') { _i++; return new Json.Arr(items); }

            while (true)
            {
                SkipWs();
                items.Add(Value(depth + 1));
                SkipWs();
                if (_i >= s.Length) throw new B1Exception("B1_ERR_PARSE", "unterminated array");
                if (s[_i] == ',') { _i++; continue; }
                if (s[_i] == ']') { _i++; return new Json.Arr(items); }
                throw new B1Exception("B1_ERR_PARSE", "expected ',' or ']'");
            }
        }

        private long Number()
        {
            var start = _i;
            if (s[_i] == '-') _i++;
            var digitsStart = _i;
            while (_i < s.Length && s[_i] is >= '0' and <= '9') _i++;
            if (_i == digitsStart) throw new B1Exception("B1_ERR_PARSE", "expected digits");
            if (_i - digitsStart > 1 && s[digitsStart] == '0')
                throw new B1Exception("B1_ERR_PARSE", "leading zero");
            if (_i < s.Length && (s[_i] == '.' || s[_i] == 'e' || s[_i] == 'E'))
                throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "non-integer");

            var text = s[start.._i];
            if (text == "-0") throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "negative zero");
            if (!long.TryParse(text, out var v) || v > MaxSafe || v < -MaxSafe)
                throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", $"out of range: {text}");
            return v;
        }

        private int Hex4()
        {
            if (_i + 4 > s.Length) throw new B1Exception("B1_ERR_PARSE", "truncated escape");
            var v = 0;
            for (var k = 0; k < 4; k++)
            {
                var c = s[_i + k];
                v <<= 4;
                v |= c switch
                {
                    >= '0' and <= '9' => c - '0',
                    >= 'a' and <= 'f' => c - 'a' + 10,
                    >= 'A' and <= 'F' => c - 'A' + 10,
                    _ => throw new B1Exception("B1_ERR_PARSE", "bad hex digit")
                };
            }
            _i += 4;
            return v;
        }

        /// <summary>
        /// Decodes one \uXXXX, joining a surrogate pair into a single scalar. .NET strings are
        /// UTF-16, so an unpaired half would survive here and fail only later; it is rejected at
        /// the point it is read.
        /// </summary>
        private void UnicodeEscape(StringBuilder into)
        {
            var cp = Hex4();
            if (cp is >= 0xD800 and <= 0xDBFF)
            {
                if (_i + 2 > s.Length || s[_i] != '\\' || s[_i + 1] != 'u')
                    throw new B1Exception("B1_ERR_INVALID_UTF8", "unpaired high surrogate");
                _i += 2;
                var low = Hex4();
                if (low is < 0xDC00 or > 0xDFFF)
                    throw new B1Exception("B1_ERR_INVALID_UTF8", "high surrogate without a low one");
                into.Append(char.ConvertFromUtf32(0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)));
                return;
            }
            if (cp is >= 0xDC00 and <= 0xDFFF)
                throw new B1Exception("B1_ERR_INVALID_UTF8", "unpaired low surrogate");
            into.Append((char)cp);
        }

        private string String()
        {
            _i++; // opening quote
            var b = new StringBuilder();
            while (true)
            {
                if (_i >= s.Length) throw new B1Exception("B1_ERR_PARSE", "unterminated string");
                var c = s[_i];
                if (c == '"') { _i++; return b.ToString(); }
                if (c == '\\')
                {
                    _i++;
                    if (_i >= s.Length) throw new B1Exception("B1_ERR_PARSE", "unterminated escape");
                    var e = s[_i];
                    _i++;
                    switch (e)
                    {
                        case '"': b.Append('"'); break;
                        case '\\': b.Append('\\'); break;
                        case '/': b.Append('/'); break;
                        case 'b': b.Append('\b'); break;
                        case 'f': b.Append('\f'); break;
                        case 'n': b.Append('\n'); break;
                        case 'r': b.Append('\r'); break;
                        case 't': b.Append('\t'); break;
                        case 'u': UnicodeEscape(b); break;
                        default: throw new B1Exception("B1_ERR_PARSE", $"bad escape \\{e}");
                    }
                    continue;
                }
                if (c < 0x20) throw new B1Exception("B1_ERR_PARSE", "raw control character");
                b.Append(c);
                _i++;
            }
        }
    }

    public static Json Parse(string text) => new Parser(text).Parse();

    private static void EscapeInto(StringBuilder o, string s)
    {
        o.Append('"');
        foreach (var ch in s)
        {
            switch (ch)
            {
                case '"': o.Append("\\\""); break;
                case '\\': o.Append("\\\\"); break;
                case '\b': o.Append("\\b"); break;
                case '\t': o.Append("\\t"); break;
                case '\n': o.Append("\\n"); break;
                case '\f': o.Append("\\f"); break;
                case '\r': o.Append("\\r"); break;
                default:
                    if (ch < 0x20) o.Append("\\u").Append(((int)ch).ToString("x4")); // lowercase
                    else o.Append(ch);
                    break;
            }
        }
        o.Append('"');
    }

    private static void CanonInto(StringBuilder o, Json v, int depth)
    {
        if (depth > MaxDepth) throw new B1Exception("B1_ERR_DEPTH", $"depth > {MaxDepth}");
        switch (v)
        {
            case Json.Null:
                o.Append("null");
                break;
            case Json.Bool b:
                o.Append(b.Value ? "true" : "false");
                break;
            case Json.Int n:
                if (n.Value > MaxSafe || n.Value < -MaxSafe)
                    throw new B1Exception("B1_ERR_NONINTEGER_NUMBER", "out of range");
                o.Append(n.Value);
                break;
            case Json.Str s:
                EscapeInto(o, s.Value);
                break;
            case Json.Arr a:
                o.Append('[');
                for (var i = 0; i < a.Items.Count; i++)
                {
                    if (i > 0) o.Append(',');
                    CanonInto(o, a.Items[i], depth + 1);
                }
                o.Append(']');
                break;
            case Json.Obj obj:
                o.Append('{');
                var first = true;
                foreach (var (k, val) in obj.Members)
                {
                    if (!KeySyntaxOk(k)) throw new B1Exception("B1_ERR_KEY_SYNTAX", k);
                    if (!first) o.Append(',');
                    first = false;
                    EscapeInto(o, k);
                    o.Append(':');
                    CanonInto(o, val, depth + 1);
                }
                o.Append('}');
                break;
            default:
                throw new B1Exception("B1_ERR_PARSE", "unknown node");
        }
    }

    public static string Canonicalize(Json v)
    {
        var b = new StringBuilder();
        CanonInto(b, v, 0);
        return b.ToString();
    }

    public static string DigestValue(Json v)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(Canonicalize(v)));
        // Lowercase is normative (SPEC/20 §3). ToHexString emits uppercase and the lowercase
        // overload is .NET 9+, so the case is forced here rather than assumed.
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    public static string DigestText(string text) => DigestValue(Parse(text));
}
