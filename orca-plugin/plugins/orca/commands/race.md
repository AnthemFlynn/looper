---
description: Race several agents on the same task in parallel Orca worktrees, then compare and recommend a winner
argument-hint: "<task description> [--agents claude,codex,...] [--repo <selector>]"
---

Use the `orca` skill (workflow 2, "Race N agents on one task") and `references/workflows.md`.

Request: $ARGUMENTS

1. Resolve the Orca CLI, confirm `status --json`, and find the repo (`--repo` if given; else the
   current worktree's repo; else ask).
2. Agents: use `--agents` if given. Otherwise use the agents this Orca has enabled, two or three
   of `claude`, `codex`, `cursor`, `opencode`, and say which you picked.
3. Write ONE self-contained brief (target, change, constraints, acceptance check, "commit on your
   branch, don't push"). Show it to the user before launching if the task is ambiguous.
4. Create one worktree per agent with `--no-parent` (default base), the same brief, a distinct
   name, and a `--comment`. Record each worktree id/path, launch handle and `prompt.outcome`.
   Never resend when the outcome is `handed-to-terminal`, `journaled` or `unconfirmed`.
5. Report the launch table right away. Then, unless the user said fire-and-forget, wait for each
   agent (bounded `terminal wait --for tui-idle`), compare the branches with git and the
   acceptance check, and recommend a winner with evidence.
6. Don't remove any worktree without explicit confirmation.
