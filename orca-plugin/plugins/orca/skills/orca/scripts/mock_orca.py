#!/usr/bin/env python3
"""Fake Orca CLI for dry-running scripts and automations that drive Orca, without Orca installed.

Put a symlink to this file named after the CLI you target (orca, orca-ide) first on PATH:
    mkdir -p /tmp/fakeorca && ln -sf "$PWD/mock_orca.py" /tmp/fakeorca/orca && export PATH=/tmp/fakeorca:$PATH
Every call is appended as a JSON argv array to $ORCA_MOCK_LOG (default /tmp/orca-mock.log), so a
test can assert which commands a script issued. Responses use the real envelope
({id, ok, result, _meta} / {ok:false, error:{code, message, data}}) and realistic receipt fields,
but the data is canned: verify field paths against a real `orca ... --json` call before relying on
them. Set ORCA_MOCK_SCHEMA to a saved `orca agent-context --json` file for realistic --help output.
"""
import json, os, sys, time
args = sys.argv[1:]
log = os.environ.get("ORCA_MOCK_LOG", "/tmp/orca-mock.log")
with open(log, "a") as f:
    f.write(json.dumps(args) + "\n")
J = "--json" in args
def out(result, ok=True, code=None, msg=None):
    if ok:
        doc = {"id": "req-%d" % int(time.time()*1000), "ok": True, "result": result, "_meta": {"runtimeId": "rt-7f3a"}}
    else:
        doc = {"id": "req-x", "ok": False, "error": {"code": code, "message": msg, "data": {}}, "_meta": {"runtimeId": "rt-7f3a"}}
    print(json.dumps(doc, indent=2) if J else (json.dumps(result) if ok else msg))
    sys.exit(0 if ok else 1)
WT = {"id": "repo-9c1::/home/dev/orca/workspaces/api/fix-auth-401", "repoId": "repo-9c1", "path": "/home/dev/orca/workspaces/api/fix-auth-401",
      "branch": "fix-auth-401", "displayName": "fix-auth-401", "comment": "goal: stop 401 storms after token expiry (user note: don't touch the session cookie code)",
      "workspaceStatus": "in-progress", "parentWorktreeId": None, "childWorktreeIds": []}
p = [a for a in args if not a.startswith("--")]
head = " ".join(p[:2])
if args[:1] in (["--version"], ["-v"]): print("orca 1.4.214"); sys.exit(0)
if not args or "--help" in args:
    want = " ".join(a for a in args if not a.startswith("--"))
    schema = os.environ.get("ORCA_MOCK_SCHEMA")
    for c in (json.load(open(schema))["commands"] if schema and os.path.exists(schema) else []):
        if c["command"] == want:
            print(c["usage"]); [print("  " + n) for n in c["notes"]]; sys.exit(0)
    print("orca <command> [--json]. Try: orca agent-context --json"); sys.exit(0)
STATE = os.environ.get("ORCA_MOCK_LOG", "/tmp/orca-mock.log") + ".state.json"
try: st = json.load(open(STATE))
except Exception: st = {}
def sel_ok(flag):
    if flag not in args: return True
    v = args[args.index(flag)+1]
    ok = v in ("active", "current") or v.split(":")[0] in ("id", "path", "branch", "name", "issue")
    if flag == "--parent-worktree": ok = ok or v.split(":")[0] in ("folder", "worktree")
    if not ok: out(None, False, "selector_not_found", "No worktree matches selector " + v, )
    return True
sel_ok("--worktree"); sel_ok("--parent-worktree")
if p[:1] == ["status"]: out({"app": "ready", "runtime": "ready", "graph": "ready", "caller": {"orcaSessionId": "sess-41b", "terminalHandle": "term_a1"}})
if p[:1] == ["open"]: out({"opened": True})
if "comment" in st: WT["comment"] = st["comment"]
if head in ("worktree current", "worktree show"): out({"worktree": WT})
if head == "worktree ps":
    out({"worktrees": [dict(WT, worktreeId=WT["id"], status="working", unread=False, agents=[{"agentType": "claude", "state": "working", "taskTitle": "fix auth 401"}])], "totalCount": 1, "truncated": False, "hostScope": {"hostIds": ["local"]}})
if head == "repo list": out({"repos": [{"id": "repo-9c1", "displayName": "api", "path": "/home/dev/code/api", "worktreeBaseRef": "origin/main"}]})
if head == "repo show": out({"repo": {"id": "repo-9c1", "displayName": "api", "path": "/home/dev/code/api", "worktreeBaseRef": "origin/main"}})
if head == "worktree create":
    name = args[args.index("--name")+1] if "--name" in args else "task"
    agent = args[args.index("--agent")+1] if "--agent" in args else None
    path = "/home/dev/orca/workspaces/api/" + name
    res = {"worktree": dict(WT, id="repo-9c1::" + path, path=path, branch=name, displayName=name, comment=""), "lineage": None, "warnings": []}
    if agent:
        res["launch"] = {"outcome": {"kind": "terminal", "handle": "term_" + name[:6] + "9", "paneKey": "tab1:leaf1"}, "worktreeId": "repo-9c1::" + path,
                         "receipt": {"mode": "terminal", "preferred": "terminal", "reason": "user_default", "detail": "Started as a terminal per your Chat UI setting."},
                         "prompt": {"delivery": "launch-command", "outcome": "handed-to-terminal"} if "--prompt" in args else None, "operationId": "op-55e"}
    out(res)
if head == "agent launch":
    out({"outcome": {"kind": "terminal", "handle": "term_ag77"}, "worktreeId": WT["id"], "receipt": {"mode": "terminal", "preferred": "terminal", "reason": "user_default", "detail": "terminal"}, "prompt": {"outcome": "handed-to-terminal"}, "operationId": "op-56"})
if head == "worktree set":
    if "--comment" in args:
        WT["comment"] = args[args.index("--comment")+1]; st["comment"] = WT["comment"]; json.dump(st, open(STATE, "w"))
    out({"worktree": WT})
if head == "terminal list": out({"terminals": [{"handle": "term_a1", "title": "Claude", "worktreeId": WT["id"], "executionHostId": "local"}], "hostScope": {"hostIds": ["local"]}})
if head == "terminal read": out({"handle": "term_a1", "source": "screen" if "--screen" in args else "stream", "text": "> Working on it...\n", "nextCursor": "c2", "latestCursor": "c2", "limited": False})
if head == "terminal send": out({"handle": "term_a1", "accepted": True, "bytesWritten": 20, "prompt": {"requestId": "rq-1", "stages": ["input_accepted"], "provider": "claude", "observation": "supported"}})
if head == "terminal wait": out({"handle": "term_a1", "satisfied": True, "for": "tui-idle"})
if p[:1] == ["orchestration"]: out({"note": "mock orchestration ok"})
if p[:2] == ["skills", "get"]:
    print("# Orca CLI guide (mock)\nUse worktree create --no-parent --agent <id> --prompt for handoffs. Prefer --json."); sys.exit(0)
if p[:1] == ["agent-context"]:
    schema = os.environ.get("ORCA_MOCK_SCHEMA")
    print(open(schema).read() if schema and os.path.exists(schema) else json.dumps({"schemaVersion": 1, "commandCount": 0, "commands": []})); sys.exit(0)
out({"mock": "generic ok", "argv": args})
