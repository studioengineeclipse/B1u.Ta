/**
 * Writes the conformance corpus. Run once; the fixtures are then static, reviewable files.
 *
 * The corpus is built to break naive implementations rather than to confirm easy cases. If an
 * implementation passes this, it genuinely parses, validates, sorts, escapes and hashes; it did not
 * merely call its language's `json.dumps` and get lucky.
 */

import { writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dir = join(here, "fixtures");
mkdirSync(dir, { recursive: true });

const w = (name, text) => {
  writeFileSync(join(dir, name), text.endsWith("\n") ? text : text + "\n");
  console.log("fixture", name);
};

/** Writes raw bytes. Needed for fixtures that are deliberately not valid UTF-8 text. */
const wb = (name, bytes) => {
  writeFileSync(join(dir, name), Buffer.from(bytes));
  console.log("fixture", name);
};

// --- positive ---------------------------------------------------------------

w("empty-object.json", "{}");
w("empty-array.json", "[]");
w("nested-empty.json", '{"a":{},"b":[],"c":[{},[]],"d":{"e":{"f":[]}}}');

// ASCII ordering: $ (24) < - (2D) < . (2E) < digits (30) < uppercase (41) < _ (5F) < lowercase (61).
// A language sorting case-insensitively, or by locale, or by UTF-16 with different rules, diverges
// here. Written deliberately out of order.
w(
  "key-order.json",
  '{"zebra":1,"Zebra":2,"_under":3,"apple":4,"Apple":5,"9nine":6,"$dollar":7,"-dash":8,".dot":9,"a":10,"A":11}',
);

// Boundary integers. 9007199254740991 is 2^53-1; a language using a 32-bit int here truncates.
w(
  "integers.json",
  '{"zero":0,"one":1,"neg":-1,"max":9007199254740991,"min":-9007199254740991,"mid":1234567890}',
);

// Escaping per RFC 8785 §3.2.2.2: short forms where they exist, lowercase \u00xx otherwise,
// and `/` deliberately NOT escaped (many JSON writers escape it by default).
w(
  "strings-escapes.json",
  JSON.stringify({
    quote: 'he said "hi"',
    backslash: "a\\b",
    slash: "a/b",
    tab: "a\tb",
    newline: "a\nb",
    cr: "a\rb",
    backspace: "a\bb",
    formfeed: "a\fb",
    control_01: "ab",
    control_1f: "ab",
  }),
);

// Non-ASCII values, including astral-plane scalars and combining marks. Values are unrestricted
// (only member names are ASCII-restricted), so these must survive as literal UTF-8.
w(
  "strings-unicode.json",
  JSON.stringify({
    latin: "café",
    japanese: "影なし",
    emoji: "🎬🎞️",
    astral: "𝕭𝟙𝛍",
    combining: "é",
    rtl: "مرحبا",
    mixed: "a→b←c",
  }),
);

// \u escapes, including a surrogate PAIR. This fixture exists because it caught a real divergence:
// a UTF-16-native language joins 🎬 into one astral scalar, while a language whose `chr`
// produces lone surrogates leaves two unpaired code points and rejects the document. Both
// implementations agreed the document was well-formed and disagreed on what it meant — the exact
// silent failure the corpus is for. The digest here must equal that of the literal emoji form.
w("unicode-escape-pair.json", '{"escaped":"\\ud83c\\udfac","literal":"🎬"}');
w("unicode-escape-basic.json", '{"a":"\\u00e9\\u0041\\u007a"}');

// Deep but legal (limit is 64).
{
  let v = "1";
  for (let i = 0; i < 60; i++) v = `[${v}]`;
  w("deep-legal.json", v);
}

// A minimal but real B1_VIDEO_IR fragment — proves the corpus exercises the actual contract shape,
// not only synthetic edge cases.
w(
  "ir-fragment.json",
  JSON.stringify({
    ir_version: "b1-video-ir/1",
    objective: "Lateral tracking shot; subject continues existing gait cycle",
    scene_mode: "continuation",
    duration_ms: 5000,
    aspect_ratio: { w: 16, h: 9 },
    target_resolution: { width_px: 1920, height_px: 1080 },
    target_frame_rate_mfps: 23976,
    camera_motion: [
      { kind: "track", start_ms: 0, end_ms: 5000, magnitude_mm: 1500 },
    ],
    reference_bindings: [
      {
        reference_id: "ref-char-01",
        role: "CHARACTER_IDENTITY",
        weight_ppm: 900000,
        applies_to: ["characters", "identity_constraints"],
        rationale: "Preserve protagonist identity across the cut",
        origin: "U",
      },
    ],
  }),
);

// The three JSON literals.
//
// This fixture exists because the corpus did not have one. Twenty-six fixtures and 364 green checks
// contained no `true`, no `false` and no `null`, and Ruby's parser was returning the *offset where
// the literal ended* instead of the literal's value — so `{"a":true}` and `{"a":9}` shared a digest
// while `[true]` and `[ true]` did not. Every B1_VIDEO_IR and every ledger record contains booleans
// and nulls; the corpus simply never asked.
w("literals.json", '{"t":true,"f":false,"n":null}');

// Literals at varying offsets, beside integers they could be confused with. A parser that yields a
// position rather than a value gives itself away here twice over: the two `true`s sit at different
// offsets, and the neighbouring integers are exactly what a position-valued literal would look like.
w(
  "literals-nested.json",
  '{"a":[true,false,null,0,1],"b":{"c":true,"d":[null,[false]]},"e":true,"f":9,"g":14}',
);

// The same document under three amounts of insignificant whitespace. Canonicalization's one promise
// is that these are indistinguishable; `expected.json` records the same digest for all three, so a
// regression that reintroduces source-position dependence fails two fixtures against a third rather
// than passing quietly. `tools/coverage.py` checks the equality is still declared.
w("whitespace-tight.json", '{"a":[true,null],"b":1}');
w("whitespace-loose.json", '{ "a" : [ true , null ] , "b" : 1 }');
w("whitespace-lines.json", '{\n  "a": [\n    true,\n    null\n  ],\n  "b": 1\n}');

// The same document with CRLF line endings — written as bytes so the CR survives.
//
// Swift rejected this and only Swift, because its parser indexed `[Character]`: a Swift `Character`
// is a grapheme cluster and `"\r\n"` is *one* cluster, equal to neither `"\r"` nor `"\n"`, so
// whitespace skipping stopped dead. Any JSON file saved on Windows was refused by one of fourteen
// implementations. No fixture had a CR in it, so nothing asked.
wb("whitespace-crlf.json",
   Buffer.from('{\r\n  "a": [\r\n    true,\r\n    null\r\n  ],\r\n  "b": 1\r\n}\r\n', "utf8"));

// --- negative ---------------------------------------------------------------

const neg = (name, text) => w(name, text);

neg("neg-float.json", '{"a":1.5}');
neg("neg-exponent.json", '{"a":1e3}');
neg("neg-too-large.json", '{"a":9007199254740992}');
neg("neg-negative-zero.json", '{"a":-0}');
neg("neg-key-space.json", '{"has space":1}');
neg("neg-key-unicode.json", '{"clé":1}');
neg("neg-key-empty.json", '{"":1}');
neg("neg-duplicate-key.json", '{"a":1,"b":2,"a":3}');
neg("neg-leading-zero.json", '{"a":01}');
neg("neg-trailing-input.json", '{"a":1} {"b":2}');
neg("neg-unterminated.json", '{"a":"x');
neg("neg-lone-high-surrogate.json", '{"a":"\\ud83c"}');
neg("neg-lone-low-surrogate.json", '{"a":"\\udfac"}');
neg("neg-lone-high-then-char.json", '{"a":"\\ud83cx"}');

{
  let v = "1";
  for (let i = 0; i < 70; i++) v = `[${v}]`;
  neg("neg-depth.json", v);
}

// Malformed UTF-8 at the byte level.
//
// The corpus had no such fixture because every fixture was written as text, and text cannot express
// the question. Three implementations — C#, Kotlin and TypeScript, including the one that owns the
// contract — decoded stdin lossily, so malformed bytes became U+FFFD before any check ran:
// `{"a":"\xff"}` and `{"a":"\xfe"}` were accepted and given the *same* digest while eleven
// implementations rejected both. A digest that survives corruption is no longer identifying bytes.
//
// Each of these violates exactly one rule. A bad byte inside a member name would violate two —
// UTF-8 validity and key syntax — and implementations legitimately differ on which they report
// first, so such a document does not belong in a corpus that records one expected token.
wb("neg-invalid-utf8-byte.json", [0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d, 0x0a]);

// A 4-byte sequence with its last byte missing: valid as far as it goes, then not.
wb("neg-truncated-utf8.json",
   [0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xf0, 0x9f, 0x8e, 0x22, 0x7d, 0x0a]);

// Overlong encoding of "/" (0xC0 0xAF). Decodes to a valid scalar under a permissive decoder, which
// is what makes it dangerous: two byte sequences would name one document.
wb("neg-overlong-utf8.json",
   [0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xc0, 0xaf, 0x22, 0x7d, 0x0a]);

// A surrogate code point encoded as if it were a scalar (CESU-8 style, 0xED 0xA0 0x80). UTF-8
// forbids it; the escaped form of the same thing is already covered by neg-lone-high-surrogate.
wb("neg-utf8-surrogate.json",
   [0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xed, 0xa0, 0x80, 0x22, 0x7d, 0x0a]);

console.log("corpus written to", dir);
