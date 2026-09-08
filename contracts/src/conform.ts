/**
 * TypeScript conformance entrypoint (SPEC/20-b1-canon-1.md §5).
 *
 *   stdin  : a JSON document
 *   stdout : 64 lowercase hex digits + newline
 *   stderr : a B1_ERR_* token when the document is rejected
 */

import { readFileSync } from "node:fs";
import { digestText, B1Error } from "./canon.js";

/**
 * Strict UTF-8.
 *
 * `readFileSync(0, "utf8")` substitutes U+FFFD for every malformed byte, so the invalid input was
 * gone before any check could see it: `{"a":"\xff"}` and `{"a":"\xfe"}` — two different documents —
 * were accepted and given the same digest, while eleven implementations rejected both. A digest
 * that survives corruption has stopped identifying the bytes it names.
 *
 * `surfaces/web/conform.mjs` has decoded strictly since it was written. The rule existed in this
 * repository and was simply not applied here, which is why the corpus now carries invalid-UTF-8
 * fixtures rather than relying on it being remembered.
 */
function readStdinStrictUtf8(): string {
  const raw = readFileSync(0);
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(raw);
  } catch {
    process.stderr.write("B1_ERR_INVALID_UTF8\n");
    process.exit(2);
  }
}

const input = readStdinStrictUtf8();

try {
  process.stdout.write(digestText(input) + "\n");
} catch (err) {
  if (err instanceof B1Error) {
    process.stderr.write(err.token + "\n");
    process.exit(2);
  }
  process.stderr.write(`B1_ERR_PARSE ${(err as Error).message}\n`);
  process.exit(2);
}
