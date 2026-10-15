#!/usr/bin/env python3
"""Programmatic grader for the orca skill evals.

Usage: python3 grade.py <iteration-dir>
Writes grading.json into every <eval>/<config>/ run directory.
"""
import json
import re
import subprocess
import sys
from pathlib import Path


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""


def check(text, passed, evidence):
    return {"text": text, "passed": bool(passed), "evidence": evidence}


def grade_handoff(out: Path):
    log = [json.loads(l) for l in read(out / "orca-calls.log").splitlines() if l.strip()]
    reply = read(out / "final_reply.md")
    calls = [" ".join(a) for a in log]
    first = lambda pred: next((i for i, a in enumerate(log) if pred(a)), None)
    exempt = lambda a: a[:1] in (["--version"], ["-v"], ["--help"]) or a[:2] == ["skills", "get"] or a[:1] == ["agent-context"]
    creates = [a for a in log if a[:2] == ["worktree", "create"]]
    sets = [a for a in log if a[:2] == ["worktree", "set"]]
    i_read = first(lambda a: a[:2] in (["worktree", "current"], ["worktree", "show"], ["worktree", "ps"]))
    i_set = first(lambda a: a[:2] == ["worktree", "set"])
    comment = ""
    for a in sets:
        if "--comment" in a:
            comment = a[a.index("--comment") + 1]
    prompt = ""
    for a in creates:
        if "--prompt" in a:
            prompt = a[a.index("--prompt") + 1]
    return [
        check("Invoked the Orca CLI via orca-ide (the Linux binary)", len(log) > 0, f"{len(log)} logged calls"),
        check("Every non-exempt Orca call used --json", log and all(exempt(a) or "--json" in a for a in log),
              "; ".join(c for c, a in zip(calls, log) if not exempt(a) and "--json" not in a) or "all had --json"),
        check("Read own worktree state before writing the card", i_read is not None and (i_set is None or i_read < i_set),
              f"read at {i_read}, first set at {i_set}"),
        check("Created a worktree with --agent codex and a --prompt",
              any("--agent" in a and a[a.index("--agent") + 1] == "codex" and "--prompt" in a for a in creates),
              "; ".join(" ".join(a)[:160] for a in creates) or "no worktree create"),
        check("New worktree is independent (--no-parent)", any("--no-parent" in a for a in creates),
              "present" if any("--no-parent" in a for a in creates) else "missing"),
        check("Brief is self-contained (names refresh.ts and rotation)",
              "refresh.ts" in prompt and re.search(r"rotat", prompt, re.I), prompt[:200]),
        check("Did not use orchestration for a plain handoff", not any(a[:1] == ["orchestration"] for a in log),
              "; ".join(c for c in calls if c.startswith("orchestration")) or "none"),
        check("Did not resend or supervise (no terminal send / terminal wait)",
              not any(a[:2] in (["terminal", "send"], ["terminal", "wait"]) for a in log),
              "; ".join(c for c in calls if c.startswith("terminal send") or c.startswith("terminal wait")) or "none"),
        check("Card comment updated and preserves the user's cookie note",
              bool(comment) and re.search(r"cookie", comment, re.I), comment[:200] or "no --comment"),
        check("Reply reports the new worktree id and agent handle",
              "repo-9c1::" in reply and "term_" in reply, "found" if ("repo-9c1::" in reply and "term_" in reply) else reply[:200]),
    ]


def grade_race(out: Path):
    s = read(out / "race.sh")
    syntax = subprocess.run(["bash", "-n", str(out / "race.sh")], capture_output=True, text=True) if s else None
    create_lines = [l for l in s.splitlines() if "worktree create" in l or "worktree\" \"create" in l]
    return [
        check("race.sh exists and passes bash -n", s and syntax.returncode == 0, (syntax.stderr if syntax else "missing")[:200]),
        check("Uses --json for Orca calls", "--json" in s, f"{s.count('--json')} occurrences"),
        check("Targets the repo with an explicit selector id:repo-9c1", "id:repo-9c1" in s or re.search(r"id:\$\{?REPO", s),
              "found" if ("id:repo-9c1" in s or re.search(r"id:\$\{?REPO", s)) else "missing"),
        check("Creates independent worktrees (--no-parent)", "--no-parent" in s, "found" if "--no-parent" in s else "missing"),
        check("Launches agents via worktree create --agent (not terminal create + typing)",
              "worktree create" in s and "--agent" in s, "; ".join(create_lines)[:200]),
        check("Captures the agent handle from the launch receipt",
              re.search(r"outcome\.handle|agentTerminalHandle", s), "found" if re.search(r"outcome\.handle|agentTerminalHandle", s) else "missing"),
        check("Bounded tui-idle wait (terminal wait --for tui-idle --timeout-ms)",
              "tui-idle" in s and "--timeout-ms" in s, "found" if ("tui-idle" in s and "--timeout-ms" in s) else "missing"),
        check("Checks the JSON envelope ok/error", re.search(r"\.ok\b|\"ok\"|\['ok'\]|error\.code", s),
              "found" if re.search(r"\.ok\b|\"ok\"|\['ok'\]|error\.code", s) else "missing"),
        check("Never deletes (no worktree rm / terminal close)", not re.search(r"worktree\s+rm|terminal\s+close|git\s+worktree\s+remove", s),
              "clean" if not re.search(r"worktree\s+rm|terminal\s+close", s) else "found deletion"),
        check("Compares with git (commit count + diffstat)", re.search(r"rev-list|log --oneline", s) and "--stat" in s or "--shortstat" in s,
              "found" if (re.search(r"rev-list|log --oneline", s) and ("--stat" in s or "--shortstat" in s)) else "missing"),
        check("Does not blindly resend the brief via terminal send",
              "terminal send" not in s or re.search(r"not-delivered", s), "ok" if ("terminal send" not in s or "not-delivered" in s) else "sends without checking prompt.outcome"),
    ]


def grade_config(out: Path):
    import yaml  # noqa: PLC0415

    y_path = out / "orca.yaml"
    y_txt = read(y_path)
    inc = read(out / ".worktreeinclude")
    reply = read(out / "final_reply.md")
    data, dup_err = None, None

    class Strict(yaml.SafeLoader):
        pass

    def no_dups(loader, node, deep=False):
        keys = [loader.construct_object(k, deep=deep) for k, _ in node.value]
        if len(keys) != len(set(keys)):
            raise ValueError(f"duplicate keys {keys}")
        return loader.construct_mapping(node, deep)

    Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dups)
    try:
        data = yaml.load(y_txt, Loader=Strict) if y_txt else None
    except Exception as exc:  # noqa: BLE001
        dup_err = str(exc)
    data = data or {}
    tabs = data.get("defaultTabs") or []
    known = {"scripts", "setupAgentStartupPolicy", "issueCommand", "defaultTabs", "worktree", "environmentRecipes"}
    inc_lines = [l.strip() for l in inc.splitlines() if l.strip() and not l.strip().startswith("#")]
    return [
        check("orca.yaml exists and parses with no duplicate keys", y_txt and dup_err is None and isinstance(data, dict), dup_err or "ok"),
        check("Only keys Orca accepts at top level", set(data) <= known, f"keys: {sorted(data)}"),
        check("scripts.setup runs pnpm install", "pnpm install" in str((data.get("scripts") or {}).get("setup", "")),
              str((data.get("scripts") or {}).get("setup", ""))[:120]),
        check("setupAgentStartupPolicy: wait-for-setup", data.get("setupAgentStartupPolicy") == "wait-for-setup", str(data.get("setupAgentStartupPolicy"))),
        check("A defaultTabs entry runs pnpm --filter web dev", any("pnpm --filter web dev" in str(t.get("command", "")) for t in tabs if isinstance(t, dict)), json.dumps(tabs)[:200]),
        check("First defaultTabs entry has no command (reserved for the agent)", bool(tabs) and isinstance(tabs[0], dict) and not tabs[0].get("command"), json.dumps(tabs[:1])),
        check("worktree.sharedDirectories includes .turbo", ".turbo" in [str(x).strip("./") for x in ((data.get("worktree") or {}).get("sharedDirectories") or [])] or ".turbo" in ((data.get("worktree") or {}).get("sharedDirectories") or []),
              str((data.get("worktree") or {}).get("sharedDirectories"))),
        check(".worktreeinclude lists .env and apps/web/.env.local as literal paths", ".env" in inc_lines and "apps/web/.env.local" in inc_lines and not any(c in inc for c in "*?!"), json.dumps(inc_lines)),
        check(".turbo is shared, not copied (absent from .worktreeinclude)", not any(l.startswith(".turbo") for l in inc_lines), json.dumps(inc_lines)),
        check("Reply explains config is read from the primary checkout", re.search(r"primary checkout|primary (repo|clone|folder)|main checkout", reply, re.I), "found" if re.search(r"primary checkout|primary (repo|clone|folder)|main checkout", reply, re.I) else "missing"),
        check("Reply warns tab commands don't wait for setup", re.search(r"(tab|dev server).{0,120}(not|n't|doesn't|does not) wait|before (the )?(install|setup) (finishes|completes)|race", reply, re.I | re.S),
              "found" if re.search(r"(tab|dev server).{0,120}(not|n't|doesn't|does not) wait|before (the )?(install|setup) (finishes|completes)|race", reply, re.I | re.S) else "missing"),
    ]


GRADERS = {"handoff-with-checkpoint": grade_handoff, "race-script": grade_race, "repo-setup-config": grade_config}


def main():
    it = Path(sys.argv[1])
    for ev_dir in sorted(p for p in it.iterdir() if p.is_dir()):
        g = GRADERS.get(ev_dir.name)
        if not g:
            continue
        runs = sorted(p for p in ev_dir.glob("*/run-*") if (p / "outputs").exists())
        runs += sorted(p for p in ev_dir.iterdir() if p.is_dir() and (p / "outputs").exists())
        for run in runs:
            exps = g(run / "outputs")
            passed = sum(e["passed"] for e in exps)
            doc = {"expectations": exps, "summary": {"passed": passed, "failed": len(exps) - passed, "total": len(exps),
                                                      "pass_rate": round(passed / len(exps), 3)}}
            (run / "grading.json").write_text(json.dumps(doc, indent=2))
            print(f"{run.relative_to(it)}: {passed}/{len(exps)}")


if __name__ == "__main__":
    main()
