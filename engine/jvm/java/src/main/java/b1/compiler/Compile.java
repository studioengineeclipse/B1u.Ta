package b1.compiler;

import b1.compiler.Canon.JArr;
import b1.compiler.Canon.JBool;
import b1.compiler.Canon.JNull;
import b1.compiler.Canon.JObj;
import b1.compiler.Canon.JStr;
import b1.compiler.Canon.Json;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * The provider-neutral compiler: B1_VIDEO_IR to provider-ready requests (SPEC/18, SPEC/70).
 *
 * <pre>
 *   stdin  : a B1_VIDEO_IR document
 *   stdout : a canonical compilation result
 * </pre>
 *
 * <p>One canonical IR is compiled independently into each provider's request shape. That is what
 * makes controlled comparison possible — same intent, same references, different render engines —
 * and it is why provider-specific syntax is never allowed to leak back into the IR.
 *
 * <p>Every emitted request carries {@code contract_status: CONTRACT_UNVERIFIED} until a live
 * provider contract has actually been observed. The shapes here are modelled from the capability
 * surface the specification describes, not from a provider's current documentation, and saying so
 * is the difference between a specification and a claim.
 */
public final class Compile {

    private static JArr referenceManifest(JObj ir) {
        List<Json> out = new ArrayList<>();
        if (ir.get("reference_bindings") instanceof JArr bindings) {
            for (Json b : bindings.items()) {
                if (!(b instanceof JObj ref)) continue;
                JObj entry = Canon.obj();
                Canon.put(entry, "reference_id", ref.get("reference_id") == null
                        ? new JStr("") : ref.get("reference_id"));
                Canon.put(entry, "role", ref.get("role") == null ? new JStr("") : ref.get("role"));
                Canon.put(entry, "media_digest", ref.get("media_digest") == null
                        ? new JNull() : ref.get("media_digest"));
                // applies_to is carried through: it is the enforcement point for the rule that a
                // reference may not influence dimensions it was not bound to.
                Canon.put(entry, "applies_to", ref.get("applies_to") == null
                        ? new JArr(List.of()) : ref.get("applies_to"));
                Canon.put(entry, "rationale", ref.get("rationale") == null
                        ? new JStr("") : ref.get("rationale"));
                // The slot a provider would map this role to is unknown until a contract is
                // verified. Guessing one produces a request that fails after spending credits.
                Canon.put(entry, "provider_slot", new JNull());
                out.add(entry);
            }
        }
        return new JArr(out);
    }

    /** A provider request shape, explicitly marked as unverified against any live contract. */
    private static JObj providerRequest(String providerId, String prompt, String negative,
                                        JObj ir, JArr manifest) {
        JObj body = Canon.obj();
        Canon.put(body, "prompt", new JStr(prompt));
        if (!negative.isEmpty()) Canon.put(body, "negative_prompt", new JStr(negative));
        Canon.put(body, "duration_ms", ir.get("duration_ms") == null ? new JNull() : ir.get("duration_ms"));
        Canon.put(body, "resolution", ir.get("target_resolution") == null
                ? new JNull() : ir.get("target_resolution"));
        Canon.put(body, "frame_rate_mfps", ir.get("target_frame_rate_mfps") == null
                ? new JNull() : ir.get("target_frame_rate_mfps"));
        Canon.put(body, "references", manifest);

        JObj req = Canon.obj();
        Canon.put(req, "provider_id", new JStr(providerId));
        Canon.put(req, "contract_status", new JStr("CONTRACT_UNVERIFIED"));
        Canon.put(req, "model", new JNull());
        Canon.put(req, "endpoint", new JNull());
        Canon.put(req, "body", body);
        return req;
    }

    public static JObj compileAll(JObj ir) {
        PromptCompiler pc = new PromptCompiler(ir);
        String prompt = pc.compile();
        String negative = pc.compileNegative();
        JArr manifest = referenceManifest(ir);

        JObj result = Canon.obj();
        Canon.put(result, "compiled_prompt", new JStr(prompt));
        Canon.put(result, "negative_prompt", negative.isEmpty() ? new JNull() : new JStr(negative));
        Canon.put(result, "reference_manifest", manifest);

        // The same IR compiled for each provider. Held side by side so a difference in results can
        // be attributed to the renderer rather than to a difference in what was asked for.
        JObj requests = Canon.obj();
        Canon.put(requests, "seedance", providerRequest("seedance", prompt, negative, ir, manifest));
        Canon.put(requests, "neta", providerRequest("neta", prompt, negative, ir, manifest));
        Canon.put(requests, "other", providerRequest("other", prompt, negative, ir, manifest));
        Canon.put(result, "provider_request", requests);

        List<Json> warnings = new ArrayList<>();
        for (String w : pc.warnings()) warnings.add(new JStr(w));
        Canon.put(result, "compiler_warnings", new JArr(warnings));

        boolean extendable = true;
        if (ir.get("final_frame_requirements") instanceof JObj ffr
                && ffr.get("must_be_extendable") instanceof JBool b) {
            extendable = b.value();
        }
        Canon.put(result, "ending_is_extendable", new JBool(extendable));
        Canon.put(result, "ir_digest", new JStr(Canon.b1c1(Canon.digestValue(ir))));
        return result;
    }

    public static void main(String[] args) throws IOException {
        byte[] raw;
        try (InputStream in = System.in) {
            raw = in.readAllBytes();
        }
        String text = new String(raw, StandardCharsets.UTF_8);

        try {
            Json parsed = Canon.parse(text);
            if (!(parsed instanceof JObj ir)) {
                System.err.println("B1_ERR_PARSE: IR must be an object");
                System.exit(2);
                return;
            }
            System.out.println(Canon.canonicalize(compileAll(ir)));
        } catch (Canon.B1Exception e) {
            System.err.println(e.token + ": " + e.getMessage());
            System.exit(2);
        }
    }
}
