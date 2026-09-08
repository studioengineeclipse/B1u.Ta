/**
 * Emits JSON Schema for every contract into contracts/generated/.
 * The other thirteen languages validate against these files; nobody hand-writes a second copy.
 */

import { writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { IR_SCHEMA } from "./ir.js";
import {
  LEDGER_SCHEMA, ENVELOPE_SCHEMA, CAPABILITY_SCHEMA, EVIDENCE_SCHEMA, PACKAGE_SCHEMA,
} from "./records.js";
import { QUALITY_SCHEMA, CONTINUITY_SCHEMA, FAILURE_SCHEMA } from "./quality.js";
import { canonicalize, sha256Hex, type JsonValue } from "./canon.js";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", "generated");

const schemas: Array<[string, unknown]> = [
  ["b1-video-ir", IR_SCHEMA],
  ["ledger-record", LEDGER_SCHEMA],
  ["authority-envelope", ENVELOPE_SCHEMA],
  ["provider-capability", CAPABILITY_SCHEMA],
  ["evidence-record", EVIDENCE_SCHEMA],
  ["generation-package", PACKAGE_SCHEMA],
  ["quality-vector", QUALITY_SCHEMA],
  ["continuity-state", CONTINUITY_SCHEMA],
  ["failure-localization", FAILURE_SCHEMA],
];

mkdirSync(outDir, { recursive: true });

const index: Record<string, string> = {};
for (const [name, schema] of schemas) {
  const text = JSON.stringify(schema, null, 2) + "\n";
  writeFileSync(join(outDir, `${name}.schema.json`), text);
  // Schema files are pretty-printed for humans; their identity is the digest of the canonical
  // form, so reformatting never changes what downstream languages consider "the same contract".
  index[name] = sha256Hex(Buffer.from(canonicalize(schema as JsonValue), "utf8"));
  console.log(`wrote ${name}.schema.json  ${index[name].slice(0, 16)}…`);
}

writeFileSync(
  join(outDir, "index.json"),
  JSON.stringify({ contract_version: "b1-contracts/1", schemas: index }, null, 2) + "\n",
);
console.log(`wrote index.json (${schemas.length} schemas)`);
