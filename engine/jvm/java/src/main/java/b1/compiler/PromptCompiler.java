package b1.compiler;

import b1.compiler.Canon.JArr;
import b1.compiler.Canon.JInt;
import b1.compiler.Canon.JObj;
import b1.compiler.Canon.JStr;
import b1.compiler.Canon.Json;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Compiles a B1_VIDEO_IR into an observable-behaviour prompt.
 * Normative: SPEC/10-b1-video-ir.md, SPEC/20 §20 (prompt compilation).
 *
 * <p>The compiler's job is to say what should be <em>observable</em> in the output, not to describe
 * how good it should be. "The camera tracks laterally 1.5 m while holding the subject at about
 * one-third frame width, and the subject continues the left-foot contact phase from the reference
 * clip" is checkable against the result. "Cinematic, smooth, professional" is not: it cannot be
 * scored, it cannot fail a gate, and it gives the renderer nothing to act on. Vague quality
 * adjectives found in the IR are reported rather than passed through silently.
 */
public final class PromptCompiler {

    /** Adjectives that assert quality without specifying anything observable. */
    private static final List<String> VAGUE = List.of(
            "cinematic", "beautiful", "stunning", "amazing", "professional", "masterpiece",
            "high quality", "best quality", "ultra", "hyper", "epic", "breathtaking",
            "photorealistic", "award-winning", "4k", "8k", "hd", "detailed", "perfect");

    private final JObj ir;
    private final List<String> warnings = new ArrayList<>();

    public PromptCompiler(JObj ir) {
        this.ir = ir;
    }

    public List<String> warnings() {
        return warnings;
    }

    private String str(Json node, String key, String fallback) {
        if (node instanceof JObj o && o.get(key) instanceof JStr s) return s.value();
        return fallback;
    }

    private long num(Json node, String key, long fallback) {
        if (node instanceof JObj o && o.get(key) instanceof JInt n) return n.value();
        return fallback;
    }

    private List<Json> arr(Json node, String key) {
        if (node instanceof JObj o && o.get(key) instanceof JArr a) return a.items();
        return List.of();
    }

    private Json child(Json node, String key) {
        return node instanceof JObj o ? o.get(key) : null;
    }

    private void scanForVagueness(String where, String text) {
        if (text == null || text.isEmpty()) return;
        String lower = text.toLowerCase(Locale.ROOT);
        for (String v : VAGUE) {
            if (lower.contains(v)) {
                warnings.add(where + ": \"" + v + "\" asserts quality without specifying anything "
                        + "observable; replace it with the behaviour it is standing in for");
            }
        }
    }

    /** Ensures a fragment taken from the IR ends a sentence, so sections do not run together. */
    private static String sentence(String text) {
        if (text == null || text.isEmpty()) return "";
        char last = text.charAt(text.length() - 1);
        return (last == '.' || last == '!' || last == '?') ? text : text + ".";
    }

    /**
     * Resolves a subject id to the name the prompt should use. The IR addresses subjects by id
     * because ids are stable across segments; the prompt is read by a renderer, which has no reason
     * to know them.
     */
    private String subjectName(String subjectId) {
        for (Json c : arr(ir, "characters")) {
            if (str(c, "id", "").equals(subjectId)) {
                String name = str(c, "name", "");
                if (!name.isEmpty()) return name;
            }
        }
        for (String key : List.of("props", "foreground_elements", "midground_elements", "background_elements")) {
            for (Json e : arr(ir, key)) {
                if (str(e, "id", "").equals(subjectId)) {
                    String name = str(e, "name", "");
                    if (!name.isEmpty()) return name;
                }
            }
        }
        return subjectId;
    }

    /** Renders milli-units into a readable quantity without reintroducing floating point. */
    private static String milli(long value, String unit) {
        long whole = value / 1000;
        long frac = Math.abs(value % 1000);
        if (frac == 0) return whole + " " + unit;
        String f = String.format("%03d", frac).replaceAll("0+$", "");
        return whole + "." + f + " " + unit;
    }

    public String compile() {
        StringBuilder p = new StringBuilder();

        String objective = str(ir, "objective", "");
        scanForVagueness("objective", objective);

        long durationMs = num(ir, "duration_ms", 0);
        Json res = child(ir, "target_resolution");
        Json ratio = child(ir, "aspect_ratio");
        long fpsMilli = num(ir, "target_frame_rate_mfps", 0);

        // SHOT — the frame everything else is described within.
        p.append("SHOT. ");
        p.append(milli(durationMs, "second")).append(" continuous take");
        if (res != null) {
            p.append(", ").append(num(res, "width_px", 0)).append("x").append(num(res, "height_px", 0));
        }
        if (ratio != null) {
            p.append(", ").append(num(ratio, "w", 0)).append(":").append(num(ratio, "h", 0));
        }
        if (fpsMilli > 0) p.append(" at ").append(milli(fpsMilli, "fps"));
        p.append(". ").append(objective).append("\n\n");

        // WHO — subjects and the identity that must survive.
        List<Json> characters = arr(ir, "characters");
        if (!characters.isEmpty()) {
            p.append("WHO. ");
            for (int i = 0; i < characters.size(); i++) {
                Json c = characters.get(i);
                if (i > 0) p.append(" ");
                p.append(str(c, "name", "subject")).append(": ").append(str(c, "description", "")).append(".");
                String anchor = str(c, "identity_anchor", "");
                if (!anchor.isEmpty()) {
                    p.append(" Identity anchor that must hold across the whole take: ")
                            .append(anchor).append(".");
                }
                String costume = str(c, "costume", "");
                if (!costume.isEmpty()) p.append(" Wearing ").append(costume).append(".");
                scanForVagueness("character " + str(c, "id", "?"), str(c, "description", ""));
            }
            p.append("\n\n");
        }

        // WHERE — environment and depth ordering.
        Json env = child(ir, "environment");
        if (env != null) {
            p.append("WHERE. ").append(sentence(str(env, "description", ""))).append(" ");
            String layout = str(env, "spatial_layout", "");
            if (!layout.isEmpty()) p.append("Spatial layout: ").append(sentence(layout));
            scanForVagueness("environment", str(env, "description", ""));
            p.append("\n\n");
        }

        List<Json> layers = arr(ir, "depth_layers");
        if (!layers.isEmpty()) {
            p.append("DEPTH. ");
            for (Json l : layers) {
                p.append("Layer ").append(num(l, "index", 0)).append(": ")
                        .append(str(l, "description", "")).append(". ");
            }
            p.append("Depth ordering must remain stable for the whole take.\n\n");
        }

        // CAMERA — position, then motion as measured quantities.
        Json camState = child(ir, "camera_state");
        List<Json> camMotion = arr(ir, "camera_motion");
        if (camState != null || !camMotion.isEmpty()) {
            p.append("CAMERA. ");
            if (camState != null) {
                String framing = str(camState, "framing", "");
                if (!framing.isEmpty()) p.append("Opens on ").append(framing).append(". ");
                long focal = num(camState, "focal_length_mm", 0);
                if (focal > 0) p.append("Lens reads as ").append(focal).append("mm. ");
            }
            for (Json m : camMotion) {
                String kind = str(m, "kind", "static");
                long start = num(m, "start_ms", 0);
                long end = num(m, "end_ms", 0);
                p.append("From ").append(milli(start, "s")).append(" to ").append(milli(end, "s"))
                        .append(", camera ").append(kind);
                if (m instanceof JObj mo && mo.get("magnitude_mm") instanceof JInt d) {
                    p.append(" ").append(milli(d.value(), "metre"));
                }
                if (m instanceof JObj mo2 && mo2.get("magnitude_mdeg") instanceof JInt deg) {
                    p.append(" ").append(milli(deg.value(), "degree"));
                }
                String note = str(m, "subject_framing_note", "");
                if (!note.isEmpty()) p.append(", ").append(note);
                p.append(". ");
            }
            p.append("\n\n");
        }

        // MOTION — with explicit phase, so a continuation can start mid-action.
        List<Json> motion = arr(ir, "subject_motion");
        if (!motion.isEmpty()) {
            p.append("MOTION. ");
            for (Json m : motion) {
                p.append(subjectName(str(m, "subject_id", "subject"))).append(" ").append(str(m, "action", ""))
                        .append(" from ").append(milli(num(m, "start_ms", 0), "s"))
                        .append(" to ").append(milli(num(m, "end_ms", 0), "s"));
                String phaseStart = str(m, "phase_at_start", "");
                if (!phaseStart.isEmpty()) {
                    p.append(", beginning already in the ").append(phaseStart).append(" phase");
                }
                String phaseEnd = str(m, "phase_at_end", "");
                if (!phaseEnd.isEmpty()) p.append(", ending in the ").append(phaseEnd).append(" phase");
                p.append(". ");
            }
            p.append("\n\n");
        }

        // INTERACTION — who acts on what, and when.
        List<Json> interactions = arr(ir, "interaction_graph");
        if (!interactions.isEmpty()) {
            p.append("INTERACTION. ");
            for (Json in : interactions) {
                p.append(subjectName(str(in, "actor_id", "?"))).append(" ").append(str(in, "relation", "interacts with"))
                        .append(" ").append(subjectName(str(in, "target_id", "?")))
                        .append(" between ").append(milli(num(in, "start_ms", 0), "s"))
                        .append(" and ").append(milli(num(in, "end_ms", 0), "s")).append(". ");
            }
            p.append("\n\n");
        }

        // LIGHT and MATERIAL.
        Json light = child(ir, "lighting");
        if (light != null) {
            p.append("LIGHT. ").append(sentence(str(light, "description", ""))).append(" ");
            String key = str(light, "key_direction", "");
            if (!key.isEmpty()) p.append("Key from ").append(sentence(key)).append(" ");
            p.append("Lighting stays consistent unless a transition is specified.\n\n");
            scanForVagueness("lighting", str(light, "description", ""));
        }

        List<Json> materials = arr(ir, "material_behavior");
        if (!materials.isEmpty()) {
            p.append("MATERIAL. ");
            for (Json m : materials) {
                p.append(str(m, "material", "")).append(" ").append(sentence(str(m, "behavior", ""))).append(" ");
            }
            p.append("\n\n");
        }

        // CONTINUITY — inherited constraints from verified history.
        List<Json> continuity = arr(ir, "continuity_constraints");
        if (!continuity.isEmpty()) {
            p.append("CONTINUITY. ");
            for (Json c : continuity) {
                p.append(str(c, "constraint", "")).append(". ");
            }
            p.append("\n\n");
        }

        // ENDING STATE — the extension-safe requirement, stated as behaviour.
        Json ffr = child(ir, "final_frame_requirements");
        p.append("ENDING STATE. ");
        boolean extendable = !(ffr instanceof JObj o && o.get("must_be_extendable") instanceof Canon.JBool b
                && !b.value());
        if (extendable) {
            p.append("The take ends mid-action. Motion in progress at the final frame must still be ")
                    .append("in progress: no settling, no held pose, no fade, no camera halt, and no ")
                    .append("object returning to a neutral position. Enough motion must remain unresolved ")
                    .append("for the next segment to continue from these frames.");
        } else {
            p.append("The event concludes within the take, as explicitly requested.");
        }
        p.append("\n");

        return p.toString().trim();
    }

    /** Negative constraints, each carrying the reason it exists. */
    public String compileNegative() {
        List<Json> negatives = arr(ir, "negative_constraints");
        if (negatives.isEmpty()) return "";
        StringBuilder n = new StringBuilder();
        for (Json c : negatives) {
            if (n.length() > 0) n.append("; ");
            n.append(str(c, "forbid", ""));
        }
        return n.toString();
    }
}
