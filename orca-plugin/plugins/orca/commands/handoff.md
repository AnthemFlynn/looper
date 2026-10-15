---
description: Hand a task off to a fresh agent in a new Orca worktree (full ownership transfer; no supervision)
argument-hint: "<task> [--agent codex|claude|...] [--model <id> --effort <level>] [--stack]"
---

Use the `orca` skill (workflow 3, "Hand off a task to a new agent").

Request: $ARGUMENTS

1. Resolve the Orca CLI and confirm `status --json`.
2. Write a self-contained brief. The receiving agent sees only the brief, so include the relevant
   context from this session: branch, findings, file paths, what was tried, the acceptance check.
3. Run `worktree create --name <slug> --agent <agent> --prompt "<brief>" --json`. Use
   `--no-parent` and the repo default base unless `--stack` was given (then pass
   `--base-branch <current branch>` and `--parent-worktree active`). Add `--model`/`--effort` only
   if specified. Default agent: `codex` if available, otherwise `claude`.
4. The handoff is done when you report the new worktree id, the agent handle, and
   `prompt.outcome` (`journaled`/`handed-to-terminal`). Don't wait for the agent to finish, and
   create no orchestration tasks. If the reply was lost, retry with `--retry-launch <operationId>`.
5. Optionally checkpoint this worktree: "handed off <task> to <agent> in <worktree>".
