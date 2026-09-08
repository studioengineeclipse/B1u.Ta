// JavaScript conformance entrypoint (SPEC/20-b1-canon-1.md §5).
//
//   stdin  : a JSON document
//   stdout : 64 lowercase hex digits + newline
//   stderr : a B1_ERR_* token when the document is rejected
//
// Uses the same canon.mjs the browser dashboard loads, so what conformance verifies is the code the
// review surface actually runs — not a second implementation that happens to sit beside it.

import { readFileSync } from "node:fs";
import { digestText, B1Error } from "./canon.mjs";

const raw = readFileSync(0);

// Strict UTF-8: the default decode substitutes U+FFFD, which would silently change the document
// and therefore its digest.
let text;
try {
  text = new TextDecoder("utf-8", { fatal: true }).decode(raw);
} catch {
  process.stderr.write("B1_ERR_INVALID_UTF8\n");
  process.exit(2);
}

try {
  process.stdout.write(digestText(text) + "\n");
} catch (err) {
  process.stderr.write((err instanceof B1Error ? err.token : "B1_ERR_PARSE") + "\n");
  process.exit(2);
}
