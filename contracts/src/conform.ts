/**
 * TypeScript conformance entrypoint (SPEC/20-b1-canon-1.md §5).
 *
 *   stdin  : a JSON document
 *   stdout : 64 lowercase hex digits + newline
 *   stderr : a B1_ERR_* token when the document is rejected
 */

import { readFileSync } from "node:fs";
import { digestText, B1Error } from "./canon.js";

const input = readFileSync(0, "utf8");

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
