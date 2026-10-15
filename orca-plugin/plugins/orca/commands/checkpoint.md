---
description: Update this worktree's Orca card (comment + status) with a concise checkpoint
argument-hint: "[message] [--status todo|in-progress|in-review|completed] [--unread]"
---

Use the `orca` skill (workflow 1, "Orient inside a worktree and checkpoint").

Arguments: $ARGUMENTS

1. Resolve the Orca CLI. Run `worktree current --json`. If this session isn't inside an
   Orca-managed worktree, say so and stop.
2. Read the existing `comment`. Keep any user-written goals or constraints that are still true.
3. If no message was given, write one from this session's actual progress: action first (what
   just happened, where), then status or next step. Keep it to one or two lines and be specific
   (files, test results).
4. Run `worktree set --worktree active --comment "<text>" [--workspace-status <id>] [--unread] --json`.
   Pass `--unread` only if it was requested, or a human must look now (blocked, needs a decision).
5. Echo the final comment and the `ok` result in one line.
