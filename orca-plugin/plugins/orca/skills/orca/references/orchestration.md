# Orca orchestration: router and cheat sheet

Orchestration is Orca's supervised multi-agent layer. It is **Experimental** (enable it under
Settings → Experimental) and has a strict safety floor, because bad lifecycle calls can kill a
worker's work or settle a task falsely.

**Authority order:**
1. `orca skills get orchestration` (and `--reference <name>` at the gates it names). This guide is
   printed by the binary you'll run, so prefer it whenever the CLI exists.
2. `official-guides/orchestration.md` + `official-guides/orchestration/references/*.md`, a copy
   of the same guide for Orca 1.4.214, for planning offline.
3. This cheat sheet, for orientation only.

## Decide your role first

| Situation | Role | Action |
| --- | --- | --- |
| User asks to supervise, monitor, wait for results, track completion, use a DAG, gates, or ask/reply | Coordinator | Supervised loop below |
| Your prompt contains a live preamble with Task ID + Dispatch ID | Dispatched worker | Follow the preamble. Worker rules below |
| User says "hand off", "give this to another agent/worktree", nothing about supervising | Handoff owner | **Not orchestration.** Use `worktree create --agent` / `agent launch`. Create no Run, Task or Dispatch |
| None of the above | Ordinary agent | Emit no lifecycle messages |

Picking a model or effort doesn't make something supervised.

## Vocabulary

- **Run**: durable namespace and coordinator inbox. It doesn't schedule anything.
- **Task**: a unit of work with a spec and deps (`pending|ready|dispatched|completed|failed|blocked`).
- **Dispatch**: one authoritative attempt of a Task on a terminal. Lifecycle authority lives here.
- **Delivery**: a FIFO batch of up to 50 inbox messages, replayed until you `--ack` it.
- **Gate**: a coordinator-owned decision blocking a Task.

## Coordinator loop (shape only; load the live guide first)

```text
orca status --json
orca orchestration run-create --objective "<objective>" --json
orca orchestration worker-start --spec "<self-contained task A>" --worktree current --agent codex --json
orca orchestration worker-start --spec "<self-contained task B>" --worktree new-child --name task-b --agent claude --json
orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 900000 --json
#   process EVERY message in the delivery:
#     question    -> orca orchestration reply --id <message_id> --body "<answer>" --json
#     worker_done -> validate against the expected active dispatch, then exactly one of:
#                    reuse (worker-start --task <next> --terminal <handle>), worker-retain, or worker-release
orca orchestration check --ack <delivery_id> --wait --types "worker_done,escalation,question" --timeout-ms 900000 --json
#   repeat until every expected dispatch settles; then:
orca orchestration worker-list --run <run_id> --terminal-state reclaimable --json   # must be empty before you finish
```

Task specs must be self-contained and name the **Target**, **Change**, **Constraints**,
**Ownership** (what the worker may edit) and **Observable acceptance**.

Rules worth remembering even without the guide:

- Start the whole independent wave before the first wait. Prefer parallel waves over dependency
  chains deeper than three or four.
- Empty waits and timeouts are checkpoints. After three empty waits, enumerate with
  `worker-list --include-remote --json` and act on each row's `projection.nextAction`.
- Only positive proof of exit (`exited` liveness, a process-exit observation, a final turn with no
  `worker_done`) authorizes `worker-stop` / `worker-abandon` / retry. `unverifiable` is absence.
- Only an accepted settlement authorizes `worker-release`. Never substitute `terminal close`.
- A valid `worker_done` settles the Task. Don't follow it with `task-update --status completed`.
- `worker-start` failed? Read `failedStage` and `residualResources`. Don't relaunch.
- A review-only `worker_done` authorizes you to synthesize findings, not to edit files yourself.

## Worker obligations (when you are dispatched)

- Copy the preamble's commands exactly: executable, handle, Task ID, Dispatch ID and any extra
  flags.
- Ask blocking questions with `orchestration ask` (resume the same message id after a timeout).
  Never open a local question prompt the coordinator can't answer.
- Heartbeat only at the preamble's cadence.
- Check for coordinator follow-ups at natural checkpoints and right before finishing:
  `orca orchestration check --terminal <your_handle> --json`. `consumer_fenced` means you were
  replaced. Stop, and send no `worker_done`.
- Finish with exactly one `worker_done`, with a three-sentence body (what changed, what you found,
  what remains), both IDs, and `--outcome succeeded|failed`. Then idle.

## Messaging extras

- Steer a running worker: `orchestration send --to dispatch:<id> --subject ... --body ...`.
  Enqueue is durable, but the wake is best-effort.
- Groups: `@all`, `@idle`, `@claude`, `@codex`, …, `@worktree:<id>`. Lifecycle messages never go
  to groups.
- Gates: `gate-create --task <id> --question ... --options '<json>'`, `gate-resolve`, `gate-list`.
- Inspect: `worker-show --dispatch <id>`, `worker-read --dispatch <id> --limit 50`,
  `task-list --ready --brief`.

Exact flags for all 30 orchestration commands: `commands/orchestration.md`.
