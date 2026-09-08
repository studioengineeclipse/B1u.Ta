/**
 * B1-CANON-1 — canonical serialization and digest.
 * Normative definition: SPEC/20-b1-canon-1.md. Normative implementation: core/c/libb1sig.
 *
 * A strict parser is required rather than JSON.parse because JSON.parse silently keeps the last
 * of a set of duplicate member names. Silent duplicate collapse is exactly the class of divergence
 * this profile exists to eliminate: two implementations would agree the document is valid and
 * disagree on its digest.
 *
 * Parsing is small here because R1 forbids floating point — number scanning is an optional minus
 * followed by digits, with no exponent, fraction, or shortest-round-trip formatting to get wrong.
 */

import { createHash } from "node:crypto";

export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [k: string]: JsonValue };

export const B1_ERRORS = [
  "B1_ERR_PARSE",
  "B1_ERR_NONINTEGER_NUMBER",
  "B1_ERR_KEY_SYNTAX",
  "B1_ERR_DUPLICATE_KEY",
  "B1_ERR_INVALID_UTF8",
  "B1_ERR_DEPTH",
] as const;

export type B1ErrorToken = (typeof B1_ERRORS)[number];

export class B1Error extends Error {
  constructor(readonly token: B1ErrorToken, detail: string) {
    super(`${token}: ${detail}`);
    this.name = "B1Error";
  }
}

const MAX_DEPTH = 64;
const MAX_SAFE = 9007199254740991; // 2^53 - 1
// R2: ASCII-only member names. Every permitted character is below U+0080, so byte, code-point and
// UTF-16 code-unit orderings coincide. `$ . -` are permitted so that JSON Schema documents
// ($schema, $id, x-b1-unit) are themselves canonicalizable.
const KEY_RE = /^[A-Za-z0-9_$.-]{1,64}$/;

// ---------------------------------------------------------------------------
// Strict parser
// ---------------------------------------------------------------------------

class Parser {
  private i = 0;
  constructor(private readonly s: string) {}

  parse(): JsonValue {
    this.ws();
    const v = this.value(0);
    this.ws();
    if (this.i !== this.s.length) throw new B1Error("B1_ERR_PARSE", `trailing input at ${this.i}`);
    return v;
  }

  private ws(): void {
    while (this.i < this.s.length) {
      const c = this.s[this.i];
      if (c === " " || c === "\t" || c === "\n" || c === "\r") this.i++;
      else break;
    }
  }

  private lit(word: string): void {
    if (this.s.startsWith(word, this.i)) this.i += word.length;
    else throw new B1Error("B1_ERR_PARSE", `expected ${word} at ${this.i}`);
  }

  private value(depth: number): JsonValue {
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
    throw new B1Error("B1_ERR_PARSE", `unexpected character ${JSON.stringify(c)} at ${this.i}`);
  }

  private object(depth: number): { [k: string]: JsonValue } {
    this.i++; // {
    const out: { [k: string]: JsonValue } = Object.create(null);
    const seen = new Set<string>();
    this.ws();
    if (this.s[this.i] === "}") { this.i++; return out; }
    for (;;) {
      this.ws();
      if (this.s[this.i] !== '"') throw new B1Error("B1_ERR_PARSE", `expected key at ${this.i}`);
      const key = this.string();
      if (!KEY_RE.test(key)) throw new B1Error("B1_ERR_KEY_SYNTAX", JSON.stringify(key));
      if (seen.has(key)) throw new B1Error("B1_ERR_DUPLICATE_KEY", key);
      seen.add(key);
      this.ws();
      if (this.s[this.i] !== ":") throw new B1Error("B1_ERR_PARSE", `expected ':' at ${this.i}`);
      this.i++;
      this.ws();
      out[key] = this.value(depth + 1);
      this.ws();
      const c = this.s[this.i];
      if (c === ",") { this.i++; continue; }
      if (c === "}") { this.i++; return out; }
      throw new B1Error("B1_ERR_PARSE", `expected ',' or '}' at ${this.i}`);
    }
  }

  private array(depth: number): JsonValue[] {
    this.i++; // [
    const out: JsonValue[] = [];
    this.ws();
    if (this.s[this.i] === "]") { this.i++; return out; }
    for (;;) {
      this.ws();
      out.push(this.value(depth + 1));
      this.ws();
      const c = this.s[this.i];
      if (c === ",") { this.i++; continue; }
      if (c === "]") { this.i++; return out; }
      throw new B1Error("B1_ERR_PARSE", `expected ',' or ']' at ${this.i}`);
    }
  }

  private number(): number {
    const start = this.i;
    if (this.s[this.i] === "-") this.i++;
    const digitsStart = this.i;
    while (this.i < this.s.length && this.s[this.i] >= "0" && this.s[this.i] <= "9") this.i++;
    if (this.i === digitsStart) throw new B1Error("B1_ERR_PARSE", `expected digits at ${start}`);
    const digits = this.s.slice(digitsStart, this.i);
    if (digits.length > 1 && digits[0] === "0") {
      throw new B1Error("B1_ERR_PARSE", `leading zero at ${digitsStart}`);
    }
    // Anything that continues the numeric grammar means a non-integer was written.
    const nxt = this.s[this.i];
    if (nxt === "." || nxt === "e" || nxt === "E") {
      throw new B1Error("B1_ERR_NONINTEGER_NUMBER", `at ${start}`);
    }
    const text = this.s.slice(start, this.i);
    if (text === "-0") throw new B1Error("B1_ERR_NONINTEGER_NUMBER", "negative zero");
    const n = Number(text);
    if (!Number.isSafeInteger(n)) {
      throw new B1Error("B1_ERR_NONINTEGER_NUMBER", `out of range: ${text}`);
    }
    return n;
  }

  private string(): string {
    this.i++; // opening quote
    let out = "";
    for (;;) {
      if (this.i >= this.s.length) throw new B1Error("B1_ERR_PARSE", "unterminated string");
      const c = this.s[this.i];
      if (c === '"') { this.i++; return out; }
      if (c === "\\") {
        this.i++;
        const e = this.s[this.i];
        this.i++;
        switch (e) {
          case '"': out += '"'; break;
          case "\\": out += "\\"; break;
          case "/": out += "/"; break;
          case "b": out += "\b"; break;
          case "f": out += "\f"; break;
          case "n": out += "\n"; break;
          case "r": out += "\r"; break;
          case "t": out += "\t"; break;
          case "u": {
            const hex = this.s.slice(this.i, this.i + 4);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
              throw new B1Error("B1_ERR_PARSE", `bad \\u escape at ${this.i}`);
            }
            this.i += 4;
            out += String.fromCharCode(parseInt(hex, 16));
            break;
          }
          default:
            throw new B1Error("B1_ERR_PARSE", `bad escape \\${e}`);
        }
        continue;
      }
      const code = this.s.charCodeAt(this.i);
      if (code < 0x20) throw new B1Error("B1_ERR_PARSE", `raw control char at ${this.i}`);
      out += c;
      this.i++;
    }
  }
}

export function parse(text: string): JsonValue {
  return new Parser(text).parse();
}

// ---------------------------------------------------------------------------
// Canonical serialization
// ---------------------------------------------------------------------------

/** RFC 8785 §3.2.2.2 escaping: short forms where they exist, lowercase \u00xx otherwise. */
function escapeString(s: string): string {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0)!;
    switch (ch) {
      case '"': out += '\\"'; continue;
      case "\\": out += "\\\\"; continue;
      case "\b": out += "\\b"; continue;
      case "\t": out += "\\t"; continue;
      case "\n": out += "\\n"; continue;
      case "\f": out += "\\f"; continue;
      case "\r": out += "\\r"; continue;
    }
    if (c < 0x20) {
      out += "\\u" + c.toString(16).padStart(4, "0"); // lowercase hex
    } else {
      out += ch;
    }
  }
  return out + '"';
}

function assertNoLoneSurrogate(s: string): void {
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

export function canonicalize(v: JsonValue, depth = 0): string {
  if (depth > MAX_DEPTH) throw new B1Error("B1_ERR_DEPTH", `depth > ${MAX_DEPTH}`);
  if (v === null) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    if (!Number.isSafeInteger(v)) throw new B1Error("B1_ERR_NONINTEGER_NUMBER", String(v));
    if (Object.is(v, -0)) throw new B1Error("B1_ERR_NONINTEGER_NUMBER", "negative zero");
    return String(v);
  }
  if (typeof v === "string") {
    assertNoLoneSurrogate(v);
    return escapeString(v);
  }
  if (Array.isArray(v)) {
    return "[" + v.map((e) => canonicalize(e, depth + 1)).join(",") + "]";
  }
  // R2 restricts names to ASCII [A-Za-z0-9_], so byte, code-point and UTF-16 code-unit
  // orderings coincide and a plain comparison is unambiguous across all fourteen languages.
  const keys = Object.keys(v).sort();
  for (const k of keys) {
    if (!KEY_RE.test(k)) throw new B1Error("B1_ERR_KEY_SYNTAX", JSON.stringify(k));
  }
  return "{" + keys.map((k) => escapeString(k) + ":" + canonicalize(v[k], depth + 1)).join(",") + "}";
}

export function sha256Hex(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** B1_DIGEST over an already-parsed value. */
export function digestValue(v: JsonValue): string {
  return sha256Hex(Buffer.from(canonicalize(v), "utf8"));
}

/** Parse strictly, then digest. This is the conformance entry path. */
export function digestText(text: string): string {
  return digestValue(parse(text));
}

/** Algorithm-labelled identifier form. The prefix is not part of the hashed input. */
export function b1c1(digestHex: string): string {
  return `b1c1:${digestHex}`;
}

export const ZERO_LINK = `b1c1:${"0".repeat(64)}`;
