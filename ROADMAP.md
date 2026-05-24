# Looper roadmap

Live milestone tracking: <https://github.com/AnthemFlynn/looper/milestones>
Issue tracker: <https://github.com/AnthemFlynn/looper/issues>

## Where looper is today

A Zig 0.16 CLI for managing cron jobs — locally, for another user, over ssh
to remote hosts, or against a plain crontab file. Static binary, libc-only,
no third-party runtime dependencies. (Kairoz is vendored as source under
`src/cron/kairoz/`; itself pure-Zig + libc.)

Shipped capabilities:

- Standard 5-field cron + `@macros`; never invents schedule syntax.
- NLP front-end: "every weekday at 8am" → `0 8 * * 1-5`, validated and
  stored as canonical cron.
- Stable `id` per managed job via a `#looper#` marker comment line.
- Mandatory backup before every mutation; `restore` + `backups prune` with
  substring-lookup for snapshot stamps.
- `enable` / `disable` without losing definitions; `import` adopts foreign
  lines; `--dry-run` previews any change as a unified diff.
- Multi-target fan-out: `-H host` (repeatable), `--all` from
  `~/.config/looper/hosts`, `-u user`, `-f path`.
- Target-timezone-aware next-run rendering — `date +%z` probed once per
  ssh round-trip and cached per run.
- `--check-command` preflight that warns if a command's binary isn't
  reachable on the target.
- One-shot scheduling: `looper once "in 5 min" "backup.sh"` (local target,
  v1; uses Kairoz for English temporal expressions).
- Output capture: `looper add --capture …` wraps the cron payload with
  the internal `_exec` subcommand, recording stdout/stderr/exit code under
  `$XDG_STATE_HOME/looper/runs/<run_id>/`.
- `runs ls / show / prune` for inspecting captured runs, with pending
  synthesis from one-shot markers that haven't fired yet.
- `doctor` preflight: crontab access, ssh reachability, backup dir,
  hosts file.
- `--json` machine-readable output for `ls`, `show`, `explain`, `runs`,
  and `--dry-run` mutations.

## Direction: looper as automation primitive for agents

The next major arc shifts looper from "a safer CLI for humans managing
cron" to "a primitive agents reach for when they need to install, observe,
and own recurring or one-shot jobs."

The implications, concretely:

- **Output must be JSON-first by default when called programmatically.**
  Agents shouldn't have to remember `--json` on every call.
- **Provenance must be a first-class concept on every managed job**, so
  multiple agents can coexist on one host without stepping on each other.
- **Silent failure of a deployed job is unacceptable.** Wrapped execution
  (the foundation already laid by `--capture`) becomes the default; raw
  bare-cron lines are an opt-out, not an opt-in.
- **Drift detection, end-to-end verification, and atomic multi-target
  apply** are the operations agents need to deploy and reconcile state
  safely.

Looper stays in scope as a *cron management tool*. It does not become a
scheduler, a daemon, or a workflow engine.

## Milestones

### v0.1 agent loop closes

The minimum looper needs to be usable as an automation primitive. Without
all four issues here, agentic loops cannot safely close because the agent
has no way to install, own, observe, or coordinate.

- [#3](https://github.com/AnthemFlynn/looper/issues/3) — wrap-by-default
  execution. The current `--capture` semantics promoted from opt-in to
  default; `--no-wrap` is the escape hatch. Silent failure and silent
  overlap become detectable by default.
- [#5](https://github.com/AnthemFlynn/looper/issues/5) — JSON-first output
  and stable schema versioning. Auto-JSON when non-TTY; `schema_version`
  in every document; documented contract in `docs/JSON_SCHEMA.md`.
- [#6](https://github.com/AnthemFlynn/looper/issues/6) — provenance
  metadata (`created_by`, `created_at`, `last_modified_by`,
  `last_modified_at`) on every managed job. `--as` / `LOOPER_AS` lets
  agents identify themselves; ownership filters prevent cross-agent
  damage.
- [#1](https://github.com/AnthemFlynn/looper/issues/1) — `looper history
  <id>` / `last` / `tail`. Reads wrap run logs first, falls back to
  syslog / journalctl. The agent's read side of the feedback loop.

### v0.2 deployable

Multi-host and multi-agent safety. Once agents can install and observe
single jobs, the next surface is "install many jobs across many hosts,
safely, with concurrent agents."

- [#2](https://github.com/AnthemFlynn/looper/issues/2) — declarative
  `apply <spec.toml>`. Idempotent state convergence; `plan` for previews;
  `--atomic` two-phase commit across targets.
- [#4](https://github.com/AnthemFlynn/looper/issues/4) — parallel ssh
  fan-out for `--all`. Bounded worker pool; per-target output buffering;
  `--stream` for interleaved completion.
- [#8](https://github.com/AnthemFlynn/looper/issues/8) — cross-caller
  locking. `flock` on local; advisory sentinel on remote; clean
  serialization for concurrent agents.

### v0.3 observability

Richer feedback once the basics work. Forward-looking schedule view,
drift detection, end-to-end verification.

- [#10](https://github.com/AnthemFlynn/looper/issues/10) — `agenda`
  (chronological "what fires next" across all targets) and `diff`
  (managed set vs. actual crontab; drift detection).
- [#7](https://github.com/AnthemFlynn/looper/issues/7) — `looper verify
  <id>`. Outside-in smoke test: schedule resolves, daemon active, wrapper
  resolvable, command resolvable.

### v0.4 mcp (RFC)

Native MCP server surface so agents can call looper via tool-use protocol
directly, with typed inputs and outputs, instead of shell + JSON parsing.

- [#9](https://github.com/AnthemFlynn/looper/issues/9) — design
  discussion before implementation. Several questions need answers first
  (transport, auth model, dep policy, in-tree vs. separate binary).

## Explicitly out of scope

These are widening moves we will not take, regardless of demand:

- Becoming a scheduler / job runner / supervisor. Cron is the scheduler;
  looper manages it.
- Adding a daemon. `looper _exec` is invoked fresh by cron per fire; we
  never daemonize.
- Adding a persistent database. The crontab is the source of truth;
  backups and run logs are flat files.
- Replacing cron itself.
- A web UI.
- Dependency graphs between jobs.
- Retry semantics, backoff policies, alerting transports.
- Adversarial multi-tenancy. The trust model is "honest agents on shared
  infrastructure," not adversarial multi-tenant isolation.
- Distributed consensus across targets.

Each of these has real competitors (Airflow, Prefect, systemd timers,
n8n, Temporal). Looper's wedge is the *safe, observable, deployable CLI
surface over the cron that's already there*.
