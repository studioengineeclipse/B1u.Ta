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

{
  let v = "1";
  for (let i = 0; i < 70; i++) v = `[${v}]`;
  neg("neg-depth.json", v);
}

console.log("corpus written to", dir);
