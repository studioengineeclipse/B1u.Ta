#!/usr/bin/env python3
"""Participation status prober (SPEC/80 §4).

Status is *derived*, never asserted. This tool compiles what claims to build, runs what claims to
execute, and runs the conformance corpus against what claims to integrate. A language whose
toolchain is absent is PLANNED with its build command documented — not BUILDS on the grounds that
the source looks correct.

Claiming a status above the evidence is the participation-map form of law L8, and it is the easiest
lie to tell in a polyglot repository because nobody checks fourteen toolchains by hand. This does.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "conformance" / "languages.json"
FIXTURES = ROOT / "conformance" / "fixtures"
EXPECTED = ROOT / "conformance" / "expected.json"
OUT = ROOT / "state" / "participation.json"

EXTRA_PATH = ["/opt/kotlinc/bin", "/opt/swift/usr/bin", "/opt/dart-sdk/bin"]

LADDER = [
    "PLANNED", "BUILDS", "EXECUTES", "INTEGRATES",
    "EFFECT_VERIFIED", "POSTCONDITION_VERIFIED", "UNKNOWN", "IN_DOUBT",
]

# The first executable named by each language's build/conform command, used only to distinguish
# "toolchain absent" from "build broken" — two very different facts that must not be merged.
TOOLCHAIN = {
    "c": "gcc", "cpp": "g++", "rust": "cargo", "typescript": "tsc", "javascript": "node",
    "go": "go", "python": "python3", "java": "javac", "kotlin": "kotlinc", "swift": "swiftc",
    "csharp": "dotnet", "php": "php", "ruby": "ruby", "dart": "dart",
}

# Source extensions per language, used to tell "not written yet" from "written but broken".
# Those are different facts: the first is PLANNED, the second is IN_DOUBT, and reporting an
# unwritten component as IN_DOUBT would overstate how far the work has got.
SOURCE_EXT = {
    "c": [".c"], "cpp": [".cpp", ".cc"], "rust": [".rs"], "typescript": [".ts"],
    "javascript": [".mjs", ".js"], "go": [".go"], "python": [".py"], "java": [".java"],
    "kotlin": [".kt"], "swift": [".swift"], "csharp": [".cs"], "php": [".php"],
    "ruby": [".rb"], "dart": [".dart"],
}


def has_source(lang: dict) -> bool:
    root = ROOT / lang["dir"]
    if not root.is_dir():
        return False
    exts = SOURCE_EXT.get(lang["id"], [])
    return any(p.suffix in exts for p in root.rglob("*") if p.is_file())


def env() -> dict:
    e = dict(os.environ)
    e["PATH"] = os.pathsep.join([e.get("PATH", "")] + EXTRA_PATH)
    return e


def have(tool: str) -> bool:
    return shutil.which(tool, path=env()["PATH"]) is not None


TOKEN_RE = re.compile(r"^B1_ERR_[A-Z0-9_]+$")


def error_token(stderr: bytes) -> str:
    """Finds the B1_ERR_* line in stderr.

    Runtimes write banner noise to stderr that has nothing to do with the document — the JVM's
    JAVA_TOOL_OPTIONS notice is the example that caught this. Taking the first line would attribute
    that noise to the implementation and report a correct rejection as a divergence, so the token is
    located rather than assumed to be first.
    """
    for line in stderr.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if TOKEN_RE.match(line):
            return line
    first = stderr.decode("utf-8", "replace").strip().splitlines()
    return first[0][:120] if first else "NO_OUTPUT"


def run(cmd: str, stdin: bytes | None = None, timeout: int = 600):
    return subprocess.run(
        cmd, shell=True, cwd=ROOT, env=env(), input=stdin,
        capture_output=True, timeout=timeout,
    )


def probe_language(lang: dict, expected: dict) -> dict:
    lid = lang["id"]
    rec = {
        "id": lid,
        "name": lang["name"],
        "responsibility": lang["responsibility"],
        "toolchain": TOOLCHAIN.get(lid),
        "toolchain_present": False,
        "build_status": "NOT_ATTEMPTED",
        "build_detail": None,
        "canon": lang.get("canon", "unrecorded"),
        "conform_available": False,
        "fixtures_checked": 0,
        "fixtures_agreed": 0,
        "divergences": [],
        "status": "PLANNED",
        "status_basis": "",
    }

    tool = TOOLCHAIN.get(lid)
    if tool and not have(tool):
        rec["status"] = "PLANNED"
        rec["status_basis"] = f"toolchain `{tool}` not present; build command documented but unrun"
        return rec
    rec["toolchain_present"] = True

    if not has_source(lang):
        rec["status"] = "PLANNED"
        rec["status_basis"] = f"toolchain present; no source under {lang['dir']} yet"
        return rec

    if lang.get("build"):
        proc = run(lang["build"])
        if proc.returncode == 0:
            rec["build_status"] = "OK"
            rec["status"] = "BUILDS"
            rec["status_basis"] = "build command succeeded"
        else:
            rec["build_status"] = "FAILED"
            rec["build_detail"] = proc.stderr.decode("utf-8", "replace")[-600:]
            rec["status"] = "IN_DOUBT"
            rec["status_basis"] = "toolchain present but build failed"
            return rec
    else:
        rec["build_status"] = "NO_BUILD_STEP"
        rec["status"] = "BUILDS"
        rec["status_basis"] = "interpreted; no build step required"

    # EXECUTES: does the conform entrypoint run and produce a well-formed answer at all?
    smoke = run(lang["conform"], stdin=b"{}")
    produced = smoke.stdout.decode().strip()
    if smoke.returncode == 0 and len(produced) == 64:
        rec["conform_available"] = True
        rec["status"] = "EXECUTES"
        rec["status_basis"] = "conform entrypoint ran and produced a digest"
    else:
        rec["status_basis"] = (
            "built, but conform entrypoint did not produce a digest: "
            + (smoke.stderr.decode("utf-8", "replace").strip()[:200] or f"exit {smoke.returncode}")
        )
        return rec

    # INTEGRATES: does it agree with the blessed corpus on every fixture?
    for name in sorted(p.name for p in FIXTURES.glob("*.json")):
        exp = expected["fixtures"].get(name)
        if exp is None:
            continue
        data = (FIXTURES / name).read_bytes()
        proc = run(lang["conform"], stdin=data)
        rec["fixtures_checked"] += 1
        if proc.returncode == 0:
            actual = "digest:" + proc.stdout.decode().strip()
        else:
            actual = "error:" + error_token(proc.stderr)
        wanted = f"{exp['kind']}:{exp[exp['kind']]}"
        if actual == wanted:
            rec["fixtures_agreed"] += 1
        else:
            rec["divergences"].append({"fixture": name, "expected": wanted, "actual": actual[:120]})

    if rec["fixtures_checked"] and rec["fixtures_agreed"] == rec["fixtures_checked"]:
        rec["status"] = "INTEGRATES"
        # How the digest was obtained decides what the agreement proves. An FFI binding to the
        # normative kernel agreeing with the normative kernel is not a second opinion, and saying
        # "agrees" without that qualifier would overstate the evidence.
        proof = {
            "normative": "normative implementation; the corpus is defined by it",
            "independent": "independent implementation, so agreement is a genuine cross-check",
            "via_c_abi": "via the C ABI to libb1sig, so this confirms the ABI boundary rather than "
                         "providing an independent check",
        }.get(rec["canon"], "provenance unrecorded")
        rec["status_basis"] = f"agrees on all {rec['fixtures_checked']} fixtures — {proof}"
    elif rec["divergences"]:
        rec["status"] = "IN_DOUBT"
        rec["status_basis"] = f"{len(rec['divergences'])} divergence(s) from the blessed corpus"

    return rec


def main() -> int:
    manifest = json.loads(MANIFEST.read_text())["languages"]
    expected = json.loads(EXPECTED.read_text()) if EXPECTED.exists() else {"fixtures": {}}

    records = [probe_language(lang, expected) for lang in manifest]

    width = max(len(r["name"]) for r in records)
    print(f"{'language'.ljust(width)}  {'status'.ljust(22)} basis")
    print("-" * (width + 26 + 40))
    for r in records:
        print(f"{r['name'].ljust(width)}  {r['status'].ljust(22)} {r['status_basis']}")

    counts: dict[str, int] = {}
    for r in records:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print()
    print("summary: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    integrating = sum(1 for r in records if r["status"] == "INTEGRATES")
    print(f"global participation invariant: {integrating}/14 at INTEGRATES or above")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "probe_version": "b1-probe/1",
        "note": "Derived by running the toolchains. Never asserted.",
        "ladder": LADDER,
        "languages": records,
        "summary": counts,
    }, indent=2) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")

    # A divergence is a hard failure; an absent toolchain is a reported fact, not a failure.
    return 1 if any(r["divergences"] for r in records) else 0


if __name__ == "__main__":
    sys.exit(main())
