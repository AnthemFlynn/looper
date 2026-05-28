# Looper roadmap

Live milestone tracking: <https://github.com/AnthemFlynn/looper/milestones>
Issue tracker: <https://github.com/AnthemFlynn/looper/issues>

## Where looper is today

A Zig 0.16 CLI for managing cron jobs — locally, for another user, over ssh
to remote hosts, or against a plain crontab file. Static binary, libc-only,
no third-party runtime dependencies. (Kairoz is vendored as source under
[`vendor/kairoz/`](vendor/README.md); itself pure-Zig + libc.)

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

### v0.1 agent loop closes — **SHIPPED**

The minimum looper needed to be usable as an automation primitive. All four
issues are landed and the contract is captured executably in
[`scripts/acceptance-v0.1.sh`](scripts/acceptance-v0.1.sh) (exit 0 == shippable).

- [x] [#3](https://github.com/AnthemFlynn/looper/issues/3) — wrap-by-default
  execution. The former `--capture` semantics are now the default; `--no-wrap`
  is the escape hatch. The `_exec` wrapper line carries `--owner=<created_by>`
  so cron-fired runs stamp provenance on the run record. Silent failure and
  silent overlap are detectable by default.
- [x] [#5](https://github.com/AnthemFlynn/looper/issues/5) — JSON-first output
  and stable schema versioning. Stdout auto-enables JSON on non-TTY;
  `schema_version: 1` rides every document; envelope shapes
  (`{schema_version, jobs}`, `{schema_version, runs}`, `{schema_version, id, runs}`)
  keep additions non-breaking. Full contract in
  [`docs/JSON_SCHEMA.md`](docs/JSON_SCHEMA.md).
- [x] [#6](https://github.com/AnthemFlynn/looper/issues/6) — provenance
  metadata (`created_by`, `created_at`, `last_modified_by`,
  `last_modified_at`) round-trips through the marker, propagates into run
  records, and is queryable via `ls --owner` / `runs ls --owner`. `--as`
  flag + `LOOPER_AS` env let agents identify themselves; CLI ingress
  validates principal values to keep the marker tokenizer safe.
- [x] [#1](https://github.com/AnthemFlynn/looper/issues/1) — `looper history
  <id>` and `looper last <id>` read the run-record store filtered by
  source_id. The runs store is the single source of truth in v0.1; a future
  cycle can layer syslog/journalctl fallback on top if needed.

**v0.1 success criterion (verified).** An agent can install a recurring task,
find out when it ran, and read what it produced — all via `looper` CLI calls
returning stable JSON. Concretely:

```sh
looper add --as agent-a --id daily-report "@hourly" "my-script.sh"
# ... time passes ...
looper runs ls --owner agent-a | jq '.runs[0]'
# { "run_id": "daily-report-<epoch>-<pid>-<n>", "source_id": "daily-report",
#   "exit_code": 0, "created_by": "agent-a", ... }
looper runs show <run_id> | jq '.captured.stdout'
# "..."
looper history daily-report | jq '.runs[0].exit_code'
# 0
looper last daily-report | jq '.exit_code'
# 0
```

All four assertions pass against the real binary; v0.1 is done.

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

### v0.4 agent power tools

Tightens the agent loop beyond v0.1's basics. With these shipped, agents
can push-subscribe to events, detect missed fires, stream live output,
query history structurally, and replay past invocations.

- [#11](https://github.com/AnthemFlynn/looper/issues/11) — `looper subscribe`
  — push event stream of run lifecycle.
- [#12](https://github.com/AnthemFlynn/looper/issues/12) — `looper missed`
  — local heartbeat / missed-fire detection (the Healthchecks.io equivalent,
  no SaaS).
- [#13](https://github.com/AnthemFlynn/looper/issues/13) — `runs show --follow`
  — stream captured output as a long-running job writes it.
- [#14](https://github.com/AnthemFlynn/looper/issues/14) — `looper runs query`
  — structured filter expression over run records.
- [#15](https://github.com/AnthemFlynn/looper/issues/15) — `looper replay
  <run_id>` — re-execute a past invocation with full wrap, linked to original.

### v0.5 ops integration

Makes looper deployable into real ops stacks. Metrics flow into Prometheus
via the daemon-free textfile-collector pattern, extensibility lives in
hooks, compliance gets append-only audit log, reliability covers downtime
via catchup semantics, multi-tenancy stays safe via per-owner quotas.

- [#16](https://github.com/AnthemFlynn/looper/issues/16) — `looper metrics`
  — Prometheus textfile-collector emission (no HTTP server, stays
  daemon-free).
- [#17](https://github.com/AnthemFlynn/looper/issues/17) — hooks —
  user-provided scripts invoked at lifecycle points. The escape valve for
  every integration that would otherwise require outbound networking
  (Slack, PagerDuty, SIEM).
- [#18](https://github.com/AnthemFlynn/looper/issues/18) — append-only audit
  log of every mutation. Compliance-grade action history, separate from
  state snapshots in backups.
- [#19](https://github.com/AnthemFlynn/looper/issues/19) — catchup semantics
  — detect and (optionally) replay missed fires after downtime. Closes the
  gap vs systemd timers' `Persistent=true`.
- [#20](https://github.com/AnthemFlynn/looper/issues/20) — per-owner quotas.
  Caps on jobs and run rate per principal; prevents runaway agent loops
  from monopolizing shared infrastructure.

### v0.6 ergonomics

The "feels modern" layer for humans. v0.4 and v0.5 serve agents and ops;
v0.6 serves the humans who maintain looper-managed systems day to day.

- [#21](https://github.com/AnthemFlynn/looper/issues/21) — `looper edit -e`
  — open the full crontab in `$EDITOR`, validate on save. The safer
  `crontab -e`.
- [#22](https://github.com/AnthemFlynn/looper/issues/22) — `looper tui` —
  full-screen terminal UI for navigation, drill-in, edit.
- [#23](https://github.com/AnthemFlynn/looper/issues/23) — shell completions
  (bash / zsh / fish) and a real man page.
- [#24](https://github.com/AnthemFlynn/looper/issues/24) — `looper export
  --format spec` — bidirectional with `apply`. The migration path from
  imperative to declarative.
- [#25](https://github.com/AnthemFlynn/looper/issues/25) — iCal export.
  Subscribe to looper's schedule from Apple Calendar / Google Calendar.

### v0.7 mcp (RFC)

Native MCP server surface so agents can call looper via tool-use protocol
directly, with typed inputs and outputs, instead of shell + JSON parsing.

Deliberately sequenced last: MCP is an *interface* over what the CLI does,
not a new capability. Designing it before the CLI surface stabilizes means
perpetual churn — ship MCP at v0.3 and you'd be retrofitting tools to it
every milestone as `subscribe`, `missed`, `query`, `replay`, `metrics`,
`hooks`, `audit`, `catchup`, `quotas`, `export` each landed. Waiting until
v0.6 lets MCP expose the stable thing once.

- [#9](https://github.com/AnthemFlynn/looper/issues/9) — design
  discussion before implementation. Several questions need answers first
  (transport, auth model, dep policy, in-tree vs. separate binary).

## Decisions deferred

### Multi-backend support (systemd timers, launchd, Task Scheduler)

Considered: extending looper to translate managed jobs onto native schedulers
on platforms where they're preferred — systemd timers on Linux distros that
use systemd, launchd on macOS, Task Scheduler on Windows. A `Target.kind`
extension translating the marker-line metadata and execution wrapper to each
backend's native format.

**Status: deferred until concrete pain emerges.** Today cron works on every
Linux fleet we target, and `_exec` already provides the unified execution
layer across platforms (capture, lock, timeout, structured logging). The
features native schedulers offer that cron can't — sub-second triggering,
event triggers, `Persistent=true` catch-up — aren't blocking the
agent-primitive thesis. When a real use case surfaces that genuinely cannot
be served by cron + `_exec`, this re-opens.

**Specifically rejected: shipping looper's own scheduling daemon.** The
operational cost of running and maintaining a daemon (boot lifecycle, signal
handling, version skew, distribution friction) is the very thing looper's
wedge avoids by riding existing infrastructure. History has not been kind
to cron alternatives (fcron, dcron, jobber, gocron, dkron, …) — every one
of them was technically respectable; none displaced cron. The reason is
operational, not technical: installing a new scheduler means changing your
deployment, audit, and monitoring story. "Compatible with what's already
there" beats "better but different" basically every time. We don't intend
to enter that graveyard.

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
