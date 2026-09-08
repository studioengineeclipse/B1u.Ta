//! B1-CANON-1: strict JSON parsing, canonical serialization, and digest.
//!
//! Normative definition: SPEC/20-b1-canon-1.md. The normative *implementation* is
//! `core/c/libb1sig`; this is an independent one, and the conformance corpus is what establishes
//! that they agree. Writing it independently rather than binding to the C library is deliberate:
//! an FFI binding would make Rust's conformance result a restatement of C's rather than a check on
//! it, and the trusted core is the last place to want a single point of agreement.

use crate::sha256::{sha256, hex};
use std::collections::BTreeMap;
use std::fmt::Write as _;

pub const MAX_DEPTH: usize = 64;
pub const MAX_SAFE: i64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum B1Error {
    Parse,
    NonIntegerNumber,
    KeySyntax,
    DuplicateKey,
    InvalidUtf8,
    Depth,
}

impl B1Error {
    pub fn token(self) -> &'static str {
        match self {
            B1Error::Parse => "B1_ERR_PARSE",
            B1Error::NonIntegerNumber => "B1_ERR_NONINTEGER_NUMBER",
            B1Error::KeySyntax => "B1_ERR_KEY_SYNTAX",
            B1Error::DuplicateKey => "B1_ERR_DUPLICATE_KEY",
            B1Error::InvalidUtf8 => "B1_ERR_INVALID_UTF8",
            B1Error::Depth => "B1_ERR_DEPTH",
        }
    }
}

impl std::fmt::Display for B1Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.token())
    }
}

impl std::error::Error for B1Error {}

/// A B1-CANON-1 value. There is no float variant: R1 forbids non-integer numbers, so the type
/// system refuses to represent a document the profile could not canonicalize.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Arr(Vec<Json>),
    /// BTreeMap keeps members in sorted order, which for ASCII-only names (R2) is exactly the
    /// canonical order — so serialization never has to sort, and can never forget to.
    Obj(BTreeMap<String, Json>),
}

impl Json {
    pub fn obj(pairs: Vec<(&str, Json)>) -> Json {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }
    pub fn s(v: impl Into<String>) -> Json {
        Json::Str(v.into())
    }
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(m) => m.get(key),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Json::Int(i) => Some(*i),
            _ => None,
        }
    }
}

pub fn key_syntax_ok(k: &str) -> bool {
    let n = k.len();
    if n == 0 || n > 64 {
        return false;
    }
    k.bytes()
        .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'$' || c == b'.' || c == b'-')
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn lit(&mut self, word: &[u8]) -> Result<(), B1Error> {
        if self.s[self.i..].starts_with(word) {
            self.i += word.len();
            Ok(())
        } else {
            Err(B1Error::Parse)
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, B1Error> {
        if depth > MAX_DEPTH {
            return Err(B1Error::Depth);
        }
        if self.i >= self.s.len() {
            return Err(B1Error::Parse);
        }
        match self.s[self.i] {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => Ok(Json::Str(self.string()?)),
            b't' => {
                self.lit(b"true")?;
                Ok(Json::Bool(true))
            }
            b'f' => {
                self.lit(b"false")?;
                Ok(Json::Bool(false))
            }
            b'n' => {
                self.lit(b"null")?;
                Ok(Json::Null)
            }
            b'-' | b'0'..=b'9' => Ok(Json::Int(self.number()?)),
            _ => Err(B1Error::Parse),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, B1Error> {
        self.i += 1;
        let mut map = BTreeMap::new();
        self.ws();
        if self.i < self.s.len() && self.s[self.i] == b'}' {
            self.i += 1;
            return Ok(Json::Obj(map));
        }
        loop {
            self.ws();
            if self.i >= self.s.len() || self.s[self.i] != b'"' {
                return Err(B1Error::Parse);
            }
            let key = self.string()?;
            if !key_syntax_ok(&key) {
                return Err(B1Error::KeySyntax);
            }
            if map.contains_key(&key) {
                return Err(B1Error::DuplicateKey);
            }
            self.ws();
            if self.i >= self.s.len() || self.s[self.i] != b':' {
                return Err(B1Error::Parse);
            }
            self.i += 1;
            self.ws();
            let v = self.value(depth + 1)?;
            map.insert(key, v);
            self.ws();
            if self.i >= self.s.len() {
                return Err(B1Error::Parse);
            }
            match self.s[self.i] {
                b',' => {
                    self.i += 1;
                }
                b'}' => {
                    self.i += 1;
                    return Ok(Json::Obj(map));
                }
                _ => return Err(B1Error::Parse),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, B1Error> {
        self.i += 1;
        let mut out = Vec::new();
        self.ws();
        if self.i < self.s.len() && self.s[self.i] == b']' {
            self.i += 1;
            return Ok(Json::Arr(out));
        }
        loop {
            self.ws();
            out.push(self.value(depth + 1)?);
            self.ws();
            if self.i >= self.s.len() {
                return Err(B1Error::Parse);
            }
            match self.s[self.i] {
                b',' => {
                    self.i += 1;
                }
                b']' => {
                    self.i += 1;
                    return Ok(Json::Arr(out));
                }
                _ => return Err(B1Error::Parse),
            }
        }
    }

    fn number(&mut self) -> Result<i64, B1Error> {
        let start = self.i;
        if self.s[self.i] == b'-' {
            self.i += 1;
        }
        let digits_start = self.i;
        while self.i < self.s.len() && self.s[self.i].is_ascii_digit() {
            self.i += 1;
        }
        if self.i == digits_start {
            return Err(B1Error::Parse);
        }
        if self.i - digits_start > 1 && self.s[digits_start] == b'0' {
            return Err(B1Error::Parse); // leading zero
        }
        if self.i < self.s.len() && matches!(self.s[self.i], b'.' | b'e' | b'E') {
            return Err(B1Error::NonIntegerNumber);
        }
        let text = std::str::from_utf8(&self.s[start..self.i]).map_err(|_| B1Error::Parse)?;
        if text == "-0" {
            return Err(B1Error::NonIntegerNumber);
        }
        let v: i64 = text.parse().map_err(|_| B1Error::NonIntegerNumber)?;
        if !(-MAX_SAFE..=MAX_SAFE).contains(&v) {
            return Err(B1Error::NonIntegerNumber);
        }
        Ok(v)
    }

    fn hex4(&mut self) -> Result<u32, B1Error> {
        if self.i + 4 > self.s.len() {
            return Err(B1Error::Parse);
        }
        let mut v = 0u32;
        for k in 0..4 {
            let c = self.s[self.i + k];
            v <<= 4;
            v |= match c {
                b'0'..=b'9' => (c - b'0') as u32,
                b'a'..=b'f' => (c - b'a' + 10) as u32,
                b'A'..=b'F' => (c - b'A' + 10) as u32,
                _ => return Err(B1Error::Parse),
            };
        }
        self.i += 4;
        Ok(v)
    }

    /// Decodes one `\uXXXX`, joining a surrogate pair into a single scalar. A high surrogate must
    /// be followed by a low one; either appearing alone is rejected. See SPEC/20 R3.
    fn unicode_escape(&mut self) -> Result<char, B1Error> {
        let cp = self.hex4()?;
        if (0xD800..=0xDBFF).contains(&cp) {
            if self.i + 2 > self.s.len() || self.s[self.i] != b'\\' || self.s[self.i + 1] != b'u' {
                return Err(B1Error::InvalidUtf8);
            }
            self.i += 2;
            let low = self.hex4()?;
            if !(0xDC00..=0xDFFF).contains(&low) {
                return Err(B1Error::InvalidUtf8);
            }
            let joined = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
            char::from_u32(joined).ok_or(B1Error::InvalidUtf8)
        } else if (0xDC00..=0xDFFF).contains(&cp) {
            Err(B1Error::InvalidUtf8)
        } else {
            char::from_u32(cp).ok_or(B1Error::InvalidUtf8)
        }
    }

    fn string(&mut self) -> Result<String, B1Error> {
        self.i += 1; // opening quote
        let mut out = String::new();
        loop {
            if self.i >= self.s.len() {
                return Err(B1Error::Parse);
            }
            let c = self.s[self.i];
            if c == b'"' {
                self.i += 1;
                return Ok(out);
            }
            if c == b'\\' {
                self.i += 1;
                if self.i >= self.s.len() {
                    return Err(B1Error::Parse);
                }
                let e = self.s[self.i];
                self.i += 1;
                match e {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{8}'),
                    b'f' => out.push('\u{c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => out.push(self.unicode_escape()?),
                    _ => return Err(B1Error::Parse),
                }
                continue;
            }
            if c < 0x20 {
                return Err(B1Error::Parse); // raw control character
            }
            // Decode one UTF-8 sequence. Rust's str::from_utf8 rejects overlong forms, encoded
            // surrogates and scalars above U+10FFFF, which is exactly the validation R3 requires.
            let len = utf8_seq_len(c);
            if len == 0 || self.i + len > self.s.len() {
                return Err(B1Error::InvalidUtf8);
            }
            let chunk = std::str::from_utf8(&self.s[self.i..self.i + len])
                .map_err(|_| B1Error::InvalidUtf8)?;
            out.push_str(chunk);
            self.i += len;
        }
    }
}

fn utf8_seq_len(first: u8) -> usize {
    match first {
        0x00..=0x7f => 1,
        0xc2..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf4 => 4,
        _ => 0,
    }
}

pub fn parse(text: &str) -> Result<Json, B1Error> {
    let mut p = Parser {
        s: text.as_bytes(),
        i: 0,
    };
    p.ws();
    let v = p.value(0)?;
    p.ws();
    if p.i != p.s.len() {
        return Err(B1Error::Parse); // trailing input
    }
    Ok(v)
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

fn escape_into(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32); // lowercase, per R3
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn canon_into(out: &mut String, v: &Json, depth: usize) -> Result<(), B1Error> {
    if depth > MAX_DEPTH {
        return Err(B1Error::Depth);
    }
    match v {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Int(i) => {
            if !(-MAX_SAFE..=MAX_SAFE).contains(i) {
                return Err(B1Error::NonIntegerNumber);
            }
            let _ = write!(out, "{i}");
        }
        Json::Str(s) => escape_into(out, s),
        Json::Arr(items) => {
            out.push('[');
            for (n, item) in items.iter().enumerate() {
                if n > 0 {
                    out.push(',');
                }
                canon_into(out, item, depth + 1)?;
            }
            out.push(']');
        }
        Json::Obj(map) => {
            out.push('{');
            // BTreeMap iterates in sorted key order; for ASCII-only names that is canonical order.
            for (n, (k, val)) in map.iter().enumerate() {
                if !key_syntax_ok(k) {
                    return Err(B1Error::KeySyntax);
                }
                if n > 0 {
                    out.push(',');
                }
                escape_into(out, k);
                out.push(':');
                canon_into(out, val, depth + 1)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

pub fn canonicalize(v: &Json) -> Result<String, B1Error> {
    let mut out = String::new();
    canon_into(&mut out, v, 0)?;
    Ok(out)
}

pub fn digest_value(v: &Json) -> Result<String, B1Error> {
    Ok(hex(&sha256(canonicalize(v)?.as_bytes())))
}

pub fn digest_text(text: &str) -> Result<String, B1Error> {
    digest_value(&parse(text)?)
}

/// Algorithm-labelled identifier form. The prefix is not part of the hashed input; it labels the
/// algorithm so a future B1-CANON-2 cannot be silently confused with this one.
pub fn b1c1(digest_hex: &str) -> String {
    format!("b1c1:{digest_hex}")
}

pub const ZERO_LINK: &str = "b1c1:0000000000000000000000000000000000000000000000000000000000000000";
