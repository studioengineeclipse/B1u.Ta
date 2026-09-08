/**
 * Minimal ambient declarations for the Node surface this package actually uses.
 *
 * Deliberately hand-written instead of depending on @types/node: the repository must build and
 * verify with no network access, and a contract layer that needs `npm install` before it can be
 * type-checked is a contract layer that quietly stops being type-checked. Only the members used
 * here are declared — anything else should fail to compile rather than be silently `any`.
 */

declare const process: {
  stdout: { write(s: string): boolean };
  stderr: { write(s: string): boolean };
  exit(code: number): never;
  argv: string[];
  env: Record<string, string | undefined>;
};

declare const console: {
  log(...args: unknown[]): void;
  error(...args: unknown[]): void;
};

interface Buffer extends Uint8Array {}

declare const Buffer: {
  from(data: string, encoding: "utf8" | "hex"): Buffer;
  from(data: ArrayBuffer | Uint8Array): Buffer;
};

declare module "node:crypto" {
  interface Hash {
    update(data: Buffer | string): Hash;
    digest(encoding: "hex"): string;
  }
  export function createHash(algorithm: string): Hash;
}

declare module "node:fs" {
  /** fd 0 reads stdin to completion. */
  export function readFileSync(path: string | number, encoding: "utf8"): string;
  export function writeFileSync(path: string, data: string): void;
  export function mkdirSync(path: string, opts: { recursive: boolean }): void;
  export function existsSync(path: string): boolean;
  export function readdirSync(path: string): string[];
}

declare module "node:path" {
  export function join(...parts: string[]): string;
  export function dirname(p: string): string;
  export function basename(p: string, ext?: string): string;
}

declare module "node:url" {
  export function fileURLToPath(url: string): string;
}

interface ImportMeta {
  url: string;
}
