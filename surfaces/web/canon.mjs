// B1-CANON-1 for JavaScript. Normative definition: SPEC/20-b1-canon-1.md.
//
// Pure JavaScript with no imports at all, including the hash. Node's crypto and the browser's
// SubtleCrypto are different APIs and SubtleCrypto is asynchronous, so depending on either would
// mean two code paths or an async canonicalizer. The dashboard is required to open from file://
// with no build step and no server, and this file is what makes that possible: the same module runs
// unchanged in Node for conformance and in the browser for review.
//
// JSON.parse is not used: it keeps the last of a set of duplicate member names, which is one of the
// silent repairs this profile exists to reject.

const MAX_DEPTH = 64;
const MAX_SAFE = 9007199254740991;
const KEY_RE = /^[A-Za-z0-9_$.-]{1,64}$/;

export class B1Error extends Error {
  constructor(token, detail) {
    super(`${token}: ${detail}`);
    this.token = token;
    this.name = "B1Error";
  }
}

// --- SHA-256 (FIPS 180-4) ----------------------------------------------------

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const rotr = (x, n) => ((x >>> n) | (x << (32 - n))) >>> 0;

export function sha256(bytes) {
  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);

  const bitLen = bytes.length * 8;
  const padded = new Uint8Array(((bytes.length + 9 + 63) >> 6) << 6);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  // Length as a 64-bit big-endian field. Written in two 32-bit halves because a single shift
  // beyond 32 bits is not defined for JavaScript's bitwise operators.
  const hi = Math.floor(bitLen / 0x100000000);
  const lo = bitLen >>> 0;
  const end = padded.length;
  padded[end - 8] = (hi >>> 24) & 0xff;
  padded[end - 7] = (hi >>> 16) & 0xff;
  padded[end - 6] = (hi >>> 8) & 0xff;
  padded[end - 5] = hi & 0xff;
  padded[end - 4] = (lo >>> 24) & 0xff;
  padded[end - 3] = (lo >>> 16) & 0xff;
  padded[end - 2] = (lo >>> 8) & 0xff;
  padded[end - 1] = lo & 0xff;

  const w = new Uint32Array(64);
  for (let off = 0; off < padded.length; off += 64) {
    for (let t = 0; t < 16; t++) {
      w[t] = ((padded[off + t * 4] << 24) | (padded[off + t * 4 + 1] << 16)
        | (padded[off + t * 4 + 2] << 8) | padded[off + t * 4 + 3]) >>> 0;
    }
    for (let t = 16; t < 64; t++) {
      const s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
      const s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
      w[t] = (s1 + w[t - 7] + s0 + w[t - 16]) >>> 0;
    }

    let [a, b, c, d, e, f, g, hh] = h;
    for (let t = 0; t < 64; t++) {
      const bsig1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + bsig1 + ch + K[t] + w[t]) >>> 0;
      const bsig0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (bsig0 + maj) >>> 0;

      hh = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }

    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
  }

  let out = "";
  for (const word of h) out += word.toString(16).padStart(8, "0");
  return out;
}

// --- strict parser -----------------------------------------------------------

class Parser {
  constructor(s) { this.s = s; this.i = 0; }

  parse() {
    this.ws();
    const v = this.value(0);
    this.ws();
    if (this.i !== this.s.length) throw new B1Error("B1_ERR_PARSE", "trailing input");
    return v;
  }

  ws() {
    while (this.i < this.s.length && " \t\n\r".includes(this.s[this.i])) this.i++;
  }

  lit(word) {
    if (this.s.startsWith(word, this.i)) this.i += word.length;
    else throw new B1Error("B1_ERR_PARSE", `expected ${word}`);
  }

  value(depth) {
    if (depth > MAX_DEPTH) throw new B1Error("B1_ERR_DEPTH", `depth > ${MAX_DEPTH}`);
    if (this.i >= this.s.length) throw new B1Error("B1_ERR_PARSE", "unexpected end of input");
    const c = this.s[this.i];
    if (c === "{") return this.object(depth);
    if (c === "[") return this.array(depth);
    if (c === '"') return this.string();
    if (c === "t") { this.lit("true"); return true; }
    if (c === "f") { this.lit("false"); return false; }
    if (c === "n") { this.lit("null"); return null; }
    if (c === "-" || (c >= "0" && c <= "9")) return this.number();
    throw new B1Error("B1_ERR_PARSE", `unexpected character ${c}`);
  }

  object(depth) {
    this.i++;
    const out = Object.create(null);
    const seen = new Set();
    this.ws();
    if (this.s[this.i] === "}") { this.i++; return out; }
    for (;;) {
      this.ws();
      if (this.s[this.i] !== '"') throw new B1Error("B1_ERR_PARSE", "expected key");
      const key = this.string();
      if (!KEY_RE.test(key)) throw new B1Error("B1_ERR_KEY_SYNTAX", key);
      if (seen.has(key)) throw new B1Error("B1_ERR_DUPLICATE_KEY", key);
      seen.add(key);
      this.ws();
      if (this.s[this.i] !== ":") throw new B1Error("B1_ERR_PARSE", "expected ':'");
      this.i++;
      this.ws();
      out[key] = this.value(depth + 1);
      this.ws();
      if (this.s[this.i] === ",") { this.i++; continue; }
      if (this.s[this.i] === "}") { this.i++; return out; }
      throw new B1Error("B1_ERR_PARSE", "expected ',' or '}'");
    }
  }

  array(depth) {
    this.i++;
    const out = [];
    this.ws();
    if (this.s[this.i] === "]") { this.i++; return out; }
    for (;;) {
      this.ws();
      out.push(this.value(depth + 1));
      this.ws();
      if (this.s[this.i] === ",") { this.i++; continue; }
      if (this.s[this.i] === "]") { this.i++; return out; }
      throw new B1Error("B1_ERR_PARSE", "expected ',' or ']'");
    }
  }

  number() {
    const start = this.i;
    if (this.s[this.i] === "-") this.i++;
    const digitsStart = this.i;
    while (this.i < this.s.length && this.s[this.i] >= "0" && this.s[this.i] <= "9") this.i++;
    if (this.i === digitsStart) throw new B1Error("B1_ERR_PARSE", "expected digits");
    const digits = this.s.slice(digitsStart, this.i);
    if (digits.length > 1 && digits[0] === "0") throw new B1Error("B1_ERR_PARSE", "leading zero");
    const next = this.s[this.i];
    if (next === "." || next === "e" || next === "E") {
      throw new B1Error("B1_ERR_NONINTEGER_NUMBER", "non-integer");
    }
    const text = this.s.slice(start, this.i);
    if (text === "-0") throw new B1Error("B1_ERR_NONINTEGER_NUMBER", "negative zero");
    const n = Number(text);
    if (!Number.isSafeInteger(n)) throw new B1Error("B1_ERR_NONINTEGER_NUMBER", `out of range: ${text}`);
    return n;
  }

  hex4() {
    const hex = this.s.slice(this.i, this.i + 4);
    if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new B1Error("B1_ERR_PARSE", "bad \\u escape");
    this.i += 4;
    return parseInt(hex, 16);
  }

  // Joins a surrogate pair into one scalar; either half alone is rejected (SPEC/20 R3).
  unicodeEscape() {
    const cp = this.hex4();
    if (cp >= 0xd800 && cp <= 0xdbff) {
      if (this.s[this.i] !== "\\" || this.s[this.i + 1] !== "u") {
        throw new B1Error("B1_ERR_INVALID_UTF8", "unpaired high surrogate");
      }
      this.i += 2;
      const low = this.hex4();
      if (low < 0xdc00 || low > 0xdfff) {
        throw new B1Error("B1_ERR_INVALID_UTF8", "high surrogate without a low one");
      }
      return String.fromCodePoint(0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00));
    }
    if (cp >= 0xdc00 && cp <= 0xdfff) {
      throw new B1Error("B1_ERR_INVALID_UTF8", "unpaired low surrogate");
    }
    return String.fromCodePoint(cp);
  }

  string() {
    this.i++;
    let out = "";
    for (;;) {
      if (this.i >= this.s.length) throw new B1Error("B1_ERR_PARSE", "unterminated string");
      const c = this.s[this.i];
      if (c === '"') { this.i++; return out; }
      if (c === "\\") {
        this.i++;
        const e = this.s[this.i];
        this.i++;
        const simple = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
        if (e in simple) { out += simple[e]; continue; }
        if (e === "u") { out += this.unicodeEscape(); continue; }
        throw new B1Error("B1_ERR_PARSE", `bad escape \\${e}`);
      }
      if (c.charCodeAt(0) < 0x20) throw new B1Error("B1_ERR_PARSE", "raw control character");
      out += c;
      this.i++;
    }
  }
}

export function parse(text) {
  return new Parser(text).parse();
}

// --- canonical serialization -------------------------------------------------

function escapeString(s) {
  let out = '"';
  for (const ch of s) {
    switch (ch) {
      case '"': out += '\\"'; continue;
      case "\\": out += "\\\\"; continue;
      case "\b": out += "\\b"; continue;
      case "\t": out += "\\t"; continue;
      case "\n": out += "\\n"; continue;
      case "\f": out += "\\f"; continue;
      case "\r": out += "\\r"; continue;
    }
    const c = ch.codePointAt(0);
    out += c < 0x20 ? "\\u" + c.toString(16).padStart(4, "0") : ch;
  }
  return out + '"';
}

function assertNoLoneSurrogate(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const n = s.charCodeAt(i + 1);
      if (!(n >= 0xdc00 && n <= 0xdfff)) throw new B1Error("B1_ERR_INVALID_UTF8", "lone high surrogate");
      i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      throw new B1Error("B1_ERR_INVALID_UTF8", "lone low surrogate");
    }
  }
}

export function canonicalize(v, depth = 0) {
  if (depth > MAX_DEPTH) throw new B1Error("B1_ERR_DEPTH", `depth > ${MAX_DEPTH}`);
  if (v === null) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    if (!Number.isSafeInteger(v)) throw new B1Error("B1_ERR_NONINTEGER_NUMBER", String(v));
    if (Object.is(v, -0)) throw new B1Error("B1_ERR_NONINTEGER_NUMBER", "negative zero");
    return String(v);
  }
  if (typeof v === "string") { assertNoLoneSurrogate(v); return escapeString(v); }
  if (Array.isArray(v)) return "[" + v.map((e) => canonicalize(e, depth + 1)).join(",") + "]";

  // R2 restricts names to ASCII, so the default sort is the canonical order.
  const keys = Object.keys(v).sort();
  for (const k of keys) if (!KEY_RE.test(k)) throw new B1Error("B1_ERR_KEY_SYNTAX", k);
  return "{" + keys.map((k) => escapeString(k) + ":" + canonicalize(v[k], depth + 1)).join(",") + "}";
}

function utf8Bytes(s) {
  const out = [];
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (cp < 0x80) out.push(cp);
    else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
  }
  return Uint8Array.from(out);
}

export function digestValue(v) {
  return sha256(utf8Bytes(canonicalize(v)));
}

export function digestText(text) {
  return digestValue(parse(text));
}

export const ZERO_LINK = "b1c1:" + "0".repeat(64);
export const b1c1 = (hex) => `b1c1:${hex}`;
