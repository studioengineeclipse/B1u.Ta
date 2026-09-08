// B1-CANON-1 for Swift. Normative definition: SPEC/20-b1-canon-1.md.
//
// Written independently rather than bridged to libb1sig, so its agreement with the normative
// implementation is a genuine cross-check rather than a restatement.

import Foundation

enum B1Error: Error {
    case parse
    case nonIntegerNumber
    case keySyntax
    case duplicateKey
    case invalidUTF8
    case depth

    var token: String {
        switch self {
        case .parse: return "B1_ERR_PARSE"
        case .nonIntegerNumber: return "B1_ERR_NONINTEGER_NUMBER"
        case .keySyntax: return "B1_ERR_KEY_SYNTAX"
        case .duplicateKey: return "B1_ERR_DUPLICATE_KEY"
        case .invalidUTF8: return "B1_ERR_INVALID_UTF8"
        case .depth: return "B1_ERR_DEPTH"
        }
    }
}

/// A canonical document. There is no floating-point case: R1 forbids non-integer numbers, so the
/// type cannot represent a document the profile would refuse.
indirect enum Json {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([Json])
    case object([String: Json])

    subscript(key: String) -> Json? {
        if case .object(let m) = self { return m[key] }
        return nil
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asInt: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }
}

let maxDepth = 64
let maxSafe: Int64 = 9_007_199_254_740_991

func keySyntaxOK(_ k: String) -> Bool {
    let bytes = Array(k.utf8)
    guard (1...64).contains(bytes.count) else { return false }
    for c in bytes {
        let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
            || c == 95 || c == 36 || c == 46 || c == 45 // _ $ . -
        if !ok { return false }
    }
    return true
}

/// ASCII hex digit value, or nil. `Unicode.Scalar` has no `hexDigitValue`, and writing it out keeps
/// the check ASCII-only — `Character.hexDigitValue` accepts fullwidth and other Unicode digits.
private func hexValue(_ c: Unicode.Scalar) -> UInt32? {
    switch c {
    case "0"..."9": return c.value - 0x30
    case "a"..."f": return c.value - 0x61 + 10
    case "A"..."F": return c.value - 0x41 + 10
    default: return nil
    }
}

struct CanonParser {
    /// Unicode **scalars**, not `Character`s.
    ///
    /// A Swift `Character` is a grapheme cluster, and `"\r\n"` is one grapheme cluster — so a parser
    /// indexing `[Character]` sees a CRLF as a single element that equals neither `"\r"` nor `"\n"`.
    /// `skipWS` therefore stopped dead on it, and any document with Windows line endings — an
    /// entirely ordinary file — was rejected by Swift alone while the other thirteen accepted it.
    ///
    /// Fixing only the whitespace comparison would have left the position model wrong: every
    /// multi-scalar cluster is one element to `[Character]` and several to every other
    /// implementation. JSON is defined over scalars, so the parser is too.
    private let s: [Unicode.Scalar]
    private var i = 0

    init(_ text: String) { s = Array(text.unicodeScalars) }

    mutating func parse() throws -> Json {
        skipWS()
        let v = try value(0)
        skipWS()
        if i != s.count { throw B1Error.parse } // trailing input
        return v
    }

    private mutating func skipWS() {
        while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" { i += 1 }
    }

    private mutating func literal(_ word: String) throws {
        let chars = Array(word.unicodeScalars)
        guard i + chars.count <= s.count, Array(s[i..<(i + chars.count)]) == chars else {
            throw B1Error.parse
        }
        i += chars.count
    }

    private mutating func value(_ depth: Int) throws -> Json {
        if depth > maxDepth { throw B1Error.depth }
        guard i < s.count else { throw B1Error.parse }
        switch s[i] {
        case "{": return try object(depth)
        case "[": return try array(depth)
        case "\"": return .string(try string())
        case "t": try literal("true"); return .bool(true)
        case "f": try literal("false"); return .bool(false)
        case "n": try literal("null"); return .null
        case "-", "0"..."9": return .int(try number())
        default: throw B1Error.parse
        }
    }

    private mutating func object(_ depth: Int) throws -> Json {
        i += 1
        var map = [String: Json]()
        skipWS()
        if i < s.count, s[i] == "}" { i += 1; return .object(map) }
        while true {
            skipWS()
            guard i < s.count, s[i] == "\"" else { throw B1Error.parse }
            let key = try string()
            guard keySyntaxOK(key) else { throw B1Error.keySyntax }
            guard map[key] == nil else { throw B1Error.duplicateKey }
            skipWS()
            guard i < s.count, s[i] == ":" else { throw B1Error.parse }
            i += 1
            skipWS()
            map[key] = try value(depth + 1)
            skipWS()
            guard i < s.count else { throw B1Error.parse }
            if s[i] == "," { i += 1; continue }
            if s[i] == "}" { i += 1; return .object(map) }
            throw B1Error.parse
        }
    }

    private mutating func array(_ depth: Int) throws -> Json {
        i += 1
        var out = [Json]()
        skipWS()
        if i < s.count, s[i] == "]" { i += 1; return .array(out) }
        while true {
            skipWS()
            out.append(try value(depth + 1))
            skipWS()
            guard i < s.count else { throw B1Error.parse }
            if s[i] == "," { i += 1; continue }
            if s[i] == "]" { i += 1; return .array(out) }
            throw B1Error.parse
        }
    }

    private mutating func number() throws -> Int64 {
        let start = i
        if s[i] == "-" { i += 1 }
        let digitsStart = i
        while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
        if i == digitsStart { throw B1Error.parse }
        if i - digitsStart > 1, s[digitsStart] == "0" { throw B1Error.parse } // leading zero
        if i < s.count, s[i] == "." || s[i] == "e" || s[i] == "E" { throw B1Error.nonIntegerNumber }

        let text = String(String.UnicodeScalarView(s[start..<i]))
        if text == "-0" { throw B1Error.nonIntegerNumber }
        guard let v = Int64(text), v <= maxSafe, v >= -maxSafe else { throw B1Error.nonIntegerNumber }
        return v
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= s.count else { throw B1Error.parse }
        var v: UInt32 = 0
        for k in 0..<4 {
            guard let d = hexValue(s[i + k]) else { throw B1Error.parse }
            v = (v << 4) | d
        }
        i += 4
        return v
    }

    /// Decodes one `\uXXXX`, joining a surrogate pair into a single scalar. Either half alone is
    /// rejected — see SPEC/20 R3.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let cp = try hex4()
        if cp >= 0xD800 && cp <= 0xDBFF {
            guard i + 2 <= s.count, s[i] == "\\", s[i + 1] == "u" else { throw B1Error.invalidUTF8 }
            i += 2
            let low = try hex4()
            guard low >= 0xDC00, low <= 0xDFFF else { throw B1Error.invalidUTF8 }
            let joined = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(joined) else { throw B1Error.invalidUTF8 }
            return scalar
        }
        if cp >= 0xDC00 && cp <= 0xDFFF { throw B1Error.invalidUTF8 }
        guard let scalar = Unicode.Scalar(cp) else { throw B1Error.invalidUTF8 }
        return scalar
    }

    private mutating func string() throws -> String {
        i += 1 // opening quote
        var out = ""
        while true {
            guard i < s.count else { throw B1Error.parse }
            let c = s[i]
            if c == "\"" { i += 1; return out }
            if c == "\\" {
                i += 1
                guard i < s.count else { throw B1Error.parse }
                let e = s[i]
                i += 1
                switch e {
                case "\"": out.unicodeScalars.append("\"")
                case "\\": out.unicodeScalars.append("\\")
                case "/": out.unicodeScalars.append("/")
                case "b": out.unicodeScalars.append("\u{8}")
                case "f": out.unicodeScalars.append("\u{c}")
                case "n": out.unicodeScalars.append("\n")
                case "r": out.unicodeScalars.append("\r")
                case "t": out.unicodeScalars.append("\t")
                case "u": out.unicodeScalars.append(try unicodeEscape())
                default: throw B1Error.parse
                }
                continue
            }
            if c.value < 0x20 { throw B1Error.parse } // raw control char
            out.unicodeScalars.append(c)
            i += 1
        }
    }
}

private func escape(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{8}": out += "\\b"
        case "\t": out += "\\t"
        case "\n": out += "\\n"
        case "\u{c}": out += "\\f"
        case "\r": out += "\\r"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value) // lowercase, per R3
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "\""
}

func canonicalize(_ v: Json, depth: Int = 0) throws -> String {
    if depth > maxDepth { throw B1Error.depth }
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let n):
        guard n <= maxSafe, n >= -maxSafe else { throw B1Error.nonIntegerNumber }
        return String(n)
    case .string(let s): return escape(s)
    case .array(let items):
        return "[" + (try items.map { try canonicalize($0, depth: depth + 1) }).joined(separator: ",") + "]"
    case .object(let map):
        // R2 restricts names to ASCII, so a plain byte-order sort is the canonical order and means
        // the same thing in every one of the fourteen languages.
        let keys = map.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var parts = [String]()
        for k in keys {
            guard keySyntaxOK(k) else { throw B1Error.keySyntax }
            parts.append(escape(k) + ":" + (try canonicalize(map[k]!, depth: depth + 1)))
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

func digestValue(_ v: Json) throws -> String {
    SHA256.hex(SHA256.digest(Array(try canonicalize(v).utf8)))
}

func digestText(_ text: String) throws -> String {
    var p = CanonParser(text)
    return try digestValue(try p.parse())
}
