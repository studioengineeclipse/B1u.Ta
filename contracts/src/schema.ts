/**
 * A minimal schema builder. One definition yields both the TypeScript type (by inference) and the
 * JSON Schema (by emission), so the contract cannot drift between what TypeScript checks and what
 * the other thirteen languages validate against.
 *
 * Dependency-free on purpose: this repository builds and verifies with no network access, and a
 * contract layer that needs an install step is a contract layer that stops being checked.
 */

export type JsonSchema = Record<string, unknown>;

export interface Node<T> {
  readonly _t?: T; // phantom, carries the inferred type
  toJsonSchema(): JsonSchema;
}

export type Infer<N> = N extends Node<infer T> ? T : never;

type ShapeOf<S extends Record<string, Node<unknown>>> = {
  [K in keyof S]: Infer<S[K]>;
};

// Optional members are marked by wrapping, so the emitted schema's `required` list and the
// TypeScript optionality come from the same declaration.
const OPTIONAL = Symbol("optional");
interface OptNode<T> extends Node<T | undefined> {
  [OPTIONAL]: true;
}

function isOptional(n: Node<unknown>): n is OptNode<unknown> {
  return (n as Partial<OptNode<unknown>>)[OPTIONAL] === true;
}

type RequiredKeys<S extends Record<string, Node<unknown>>> = {
  [K in keyof S]: undefined extends Infer<S[K]> ? never : K;
}[keyof S];

type ObjectType<S extends Record<string, Node<unknown>>> =
  { [K in RequiredKeys<S>]: Infer<S[K]> } &
  { [K in Exclude<keyof S, RequiredKeys<S>>]?: Infer<S[K]> };

/**
 * An integer carrying a unit suffix, per SPEC/20-b1-canon-1.md §4. The unit is not decoration:
 * it is what lets the no-floating-point rule describe camera motion and timing without loss.
 */
export type Unit = "ms" | "ppm" | "mu" | "mdeg" | "mm" | "mfps" | "px" | "count" | "unitless";

export const s = {
  int(unit: Unit = "unitless", opts: { min?: number; max?: number; note?: string } = {}): Node<number> {
    return {
      toJsonSchema: () => ({
        type: "integer",
        ...(opts.min !== undefined ? { minimum: opts.min } : {}),
        ...(opts.max !== undefined ? { maximum: opts.max } : {}),
        "x-b1-unit": unit,
        ...(opts.note ? { description: opts.note } : {}),
      }),
    };
  },

  /** Milli-units, 0..1000. The system's standard score scale. */
  score(note?: string): Node<number> {
    return s.int("mu", { min: 0, max: 1000, note });
  },

  /** Parts per million, 0..1000000. The system's standard ratio scale. */
  ppm(note?: string): Node<number> {
    return s.int("ppm", { min: 0, max: 1_000_000, note });
  },

  str(opts: { pattern?: string; note?: string } = {}): Node<string> {
    return {
      toJsonSchema: () => ({
        type: "string",
        ...(opts.pattern ? { pattern: opts.pattern } : {}),
        ...(opts.note ? { description: opts.note } : {}),
      }),
    };
  },

  bool(note?: string): Node<boolean> {
    return { toJsonSchema: () => ({ type: "boolean", ...(note ? { description: note } : {}) }) };
  },

  lit<const V extends string>(value: V): Node<V> {
    return { toJsonSchema: () => ({ const: value }) };
  },

  enum<const V extends readonly string[]>(values: V): Node<V[number]> {
    return { toJsonSchema: () => ({ enum: [...values] }) };
  },

  arr<N extends Node<unknown>>(item: N, note?: string): Node<Infer<N>[]> {
    return {
      toJsonSchema: () => ({
        type: "array",
        items: item.toJsonSchema(),
        ...(note ? { description: note } : {}),
      }),
    };
  },

  obj<S extends Record<string, Node<unknown>>>(shape: S, note?: string): Node<ObjectType<S>> {
    return {
      toJsonSchema: () => {
        const properties: Record<string, JsonSchema> = {};
        const required: string[] = [];
        for (const [k, v] of Object.entries(shape)) {
          properties[k] = v.toJsonSchema();
          if (!isOptional(v)) required.push(k);
        }
        return {
          type: "object",
          properties,
          ...(required.length ? { required } : {}),
          additionalProperties: false,
          ...(note ? { description: note } : {}),
        };
      },
    };
  },

  /** Nullable — distinct from optional. `null` means measured-and-absent; missing means unstated. */
  nullable<N extends Node<unknown>>(inner: N): Node<Infer<N> | null> {
    return {
      toJsonSchema: () => ({ anyOf: [inner.toJsonSchema(), { type: "null" }] }),
    };
  },

  opt<N extends Node<unknown>>(inner: N): Node<Infer<N> | undefined> {
    const node: OptNode<Infer<N>> = {
      [OPTIONAL]: true,
      toJsonSchema: () => inner.toJsonSchema(),
    };
    return node;
  },

  union<const NS extends readonly Node<unknown>[]>(...members: NS): Node<Infer<NS[number]>> {
    return { toJsonSchema: () => ({ anyOf: members.map((m) => m.toJsonSchema()) }) };
  },

  /** A b1c1: digest reference. */
  digestRef(note?: string): Node<string> {
    return s.str({ pattern: "^b1c1:[0-9a-f]{64}$", note });
  },
};

export function emit(id: string, title: string, node: Node<unknown>): JsonSchema {
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: `https://b1.local/schema/${id}`,
    title,
    ...node.toJsonSchema(),
  };
}

export type { ShapeOf };
