---
description: Coordinate several Orca agents as a supervised orchestration run (tasks, waits, results)
argument-hint: "<objective>"
---

Use the `orca` skill (§4.4) and `references/orchestration.md`.

Objective: $ARGUMENTS

1. Resolve the Orca CLI, confirm `status --json`, then load the live guide with
   `skills get orchestration` and follow it over any summary. If the CLI lacks it, use
   `references/official-guides/orchestration.md`. If orchestration commands are refused because
   the feature is off, tell the user to enable Settings → Experimental and stop.
2. Break the objective into independent tasks, each with Target, Change, Constraints, Ownership
   and Observable acceptance. Show the plan to the user and confirm before starting workers.
3. `run-create`, start the whole independent wave with `worker-start`, then run the
   `check --wait` / process-every-message / `--ack` loop until every dispatch settles. Account for
   every settled worker (reuse, retain or release).
4. Finish with a per-task report: outcome, evidence, and any unresolved blocker. Never stop, retry
   or release a worker without the positive proof the guide requires.
