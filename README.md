# looper

A sharp little CLI that manages one-to-many cron jobs — locally, for another
user, across remote hosts over **ssh**, or in a plain crontab file. One job,
done well: **manage cron jobs**. It speaks standard 5-field cron plus the
`@macros` cron already understands; it never invents a scheduler syntax.

Modular Zig 0.16 codebase under `src/`, no dependencies beyond libc, static
binaries for every box in a mixed-arch fleet.

```
$ looper ls
ID            SCHEDULE              NEXT RUN                               COMMAND
db-backup     0 3 * * *             2026-05-22 03:00 PDT  in 1h 14m      ● /usr/local/bin/backup.sh --db
tidy          */15 9-17 * * mon-fri 2026-05-22 09:00 PDT  in 7h 14m      ● tidy-temp
warmup        @reboot               at boot                              ○ /opt/legacy/warmup.sh
```

## Why it exists

Raw `crontab` has a handful of well-documented failure modes. Every feature
here maps to one of them:

| Cron pain point | What looper does |
|---|---|
| `crontab -r` sits one key from `crontab -e` and wipes everything, no undo | **There is no "remove all" command.** Every mutation auto-backs-up first; `restore` rolls back. |
| The crontab is an opaque blob — jobs have no identity | Each job carries a stable **`id`** via a `#looper#` marker line. |
| Re-running a provisioning script appends duplicate jobs | `add` is **idempotent** by id — it updates in place. |
| Cron expressions read like regex | `ls`, `show`, and `explain` print **plain English + the next run times**. |
| One syntax error breaks the whole file | Schedules are **validated before any write**. |
| You can't pause a job without losing its definition | `disable`/`enable` comment the line in place but keep the job. |
| Managing many hosts means SSHing into each | `-H host` / `--all` run the **same commands** locally or remotely. |

## Install

Requires Zig 0.16+ (only libc is needed; no other dependencies).

```sh
git clone https://github.com/AnthemFlynn/looper && cd looper
make install                    # → ~/.local/bin/looper
looper --help
```

`make install` runs `zig build -Doptimize=ReleaseSafe --prefix ~/.local`,
which is what the rule expands to. Override the prefix with `PREFIX=`:

```sh
make install PREFIX=/usr/local        # system-wide
make install PREFIX=$HOME/bin         # somewhere else
```

If the install location isn't on your `$PATH`, the rule prints exactly the
`export PATH=...` line to add to your shell rc, so you don't have to guess.

Prefer the raw Zig invocation? It's equivalent:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

### Cross-compiling for a whole fleet

Zig cross-compiles from any host. To rebuild every target into `zig-out/bin/`:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
```

The `*-linux-musl` builds are statically linked — copy them to a Pi and run,
no runtime, no libc version to match. Drop the binary into `~/.local/bin/looper`
(or `/usr/local/bin/looper`) on the target host; that's the whole deployment.

## Usage

```
looper <command> [args] [options]

Commands
  ls                       list jobs (managed + unmanaged) with next run times
  add <schedule> <cmd>     add or update a job (idempotent; wraps by default; --id to name it)
  edit <id>                partial update: --schedule X and/or --command Y
  rm <id|fN>...            remove job(s) by id, or unmanaged ones by fN handle
  enable / disable <id...> toggle a job without deleting its definition
  show <id>                detail: meaning + next 5 run times + provenance
  run <id>                 run a job's command right now (produces a run record)
  history <id>             list past runs for a job (newest first)
  last <id>                show the most recent run for a job
  explain <schedule>       explain a cron expression + next runs (writes nothing)
  once <when> <command>    schedule a one-shot; fires once then self-removes
  import                   adopt existing unmanaged jobs into looper
  backup                   snapshot the current crontab
  backups                  list snapshots (newest first; size + age)
  backups prune --keep N   remove older snapshots, keep the newest N
  restore [file|--from S]  roll back to the newest, a named file, or a stamp
  doctor                   preflight: crontab/ssh, backup dir, hosts file, targets
  runs ls                  list captured runs (one-shots + wrapped jobs)
  runs show <run_id>       inspect a single run: meta, stdout, stderr, exit code
  runs prune --older-than  remove run records older than the given seconds
  version | help

Target (default: your local crontab)
  -H, --host <[user@]host> remote host via ssh (repeatable)
      --all                every host listed in ~/.config/looper/hosts
  -u, --user <user>        another user's crontab (crontab -u)
  -f, --file <path>        a plain crontab file (great for git-tracked crontabs)

Options
      --dry-run            show the diff that would be written; write nothing
  -y, --yes                assume yes (required for destructive ops without a tty)
      --json               machine-readable output (auto-enabled when stdout is not a TTY)
  -q, --quiet              only print errors
      --no-color           disable color (also honored: NO_COLOR)
      --no-target-tz       skip remote TZ probe; render everything as controller-local
      --as <principal>     (add/edit) stamp this actor on the job (env: LOOPER_AS)
      --owner <principal>  (ls/runs ls) filter to jobs/runs owned by this principal
      --no-wrap            (add) opt out of wrap-by-default — produce a bare cron line
      --capture            (add) synonym for the default (kept for compatibility)
      --check-command      (add) warn if the command binary isn't on the target
      --status <s>         (runs ls) filter by pending|running|done|failed
      --older-than <secs>  (runs prune) cutoff age in seconds (default 30 days)
      --full               (runs show) emit full captured output, no inline cap

Environment
  LOOPER_AS                fallback for --as (agents typically export this once)
  LOOPER_CRONTAB_FILE      fallback for --file when no other target is supplied
  XDG_STATE_HOME           base for backups and run records (default ~/.local/state)
  XDG_CONFIG_HOME          base for the --all hosts file (default ~/.config)
  NO_COLOR                 disable color output (any non-empty value)
```

### Examples

```sh
# A nightly DB backup, named so it can be managed later
looper add --id db-backup "0 3 * * *" "/usr/local/bin/backup.sh --db"

# Idempotent: run this again in a provisioning script — it updates, never duplicates
looper add --id db-backup "0 4 * * *" "/usr/local/bin/backup.sh --db"

# What does this expression actually mean, and when does it fire?
looper explain "*/15 9-17 * * mon-fri"

# Pause a job for a maintenance window, bring it back later
looper disable db-backup
looper enable  db-backup

# See the change before committing to it
looper --dry-run add --id pinger "*/5 * * * *" "ping -c1 nas"

# Test a job's command immediately (no waiting for the scheduler)
looper run db-backup

# The whole fleet at once
looper --all ls
looper -H pi@nas -H pi@media add --id reboot-clean "@reboot" "/opt/clean.sh"

# Verify the binary actually exists on the target before scheduling it.
# Warns and continues — most cron failures are silent PATH/environment
# failures the user only finds out about from the mail spool the next day.
looper -H pi@nas add --check-command --id rep "@daily" "/opt/bin/report.sh"
# → ! command '/opt/bin/report.sh' not found on pi@nas — cron may fail to run

# Schedule a one-shot — fires once at the given moment, then self-cleans
looper once "in 5 min" "backup.sh"
looper once "tomorrow at 8am" "/opt/bin/report.sh"

# Capture every fire's stdout/stderr/exit code into the runs store
looper add --capture @daily "/opt/bin/report.sh"
looper runs ls                                    # what fired, when, status
looper runs show <run_id>                         # full meta + output
```

## Natural-language schedules

Anywhere a schedule is accepted (`add`, `explain`), you can write plain English
instead of cron. It is compiled to a standard cron expression, validated, and
**stored as cron** — looper echoes what it interpreted so nothing is hidden:

```sh
$ looper add "every weekday at 8am" report.sh
interpreted "every weekday at 8am" as 0 8 * * 1-5  (at 08:00 on Mon-Fri)
```

Preview without changing anything:

```sh
$ looper explain "every 15 min from 9am to 5pm on weekdays"
"every 15 min from 9am to 5pm on weekdays" -> */15 9-17 * * 1-5
  every 15 minutes on Mon-Fri
  next runs:
    ...
```

Understood phrasings include: `every minute`, `every 15 minutes`,
`every 2 hours`, `hourly`/`daily`/`weekly`/`monthly`/`yearly`, `at 3am`,
`at 9:30pm`, `noon`, `midnight`, `every day at 6am`, `weekdays`/`weekends`,
specific days (`every monday and thursday at 5pm`), day ranges
(`monday to friday`), day-of-month (`on the 1st`, `15th of the month`),
`@reboot` (`on reboot`, `at startup`), and an hour window for intervals
(`from 9am to 5pm`). If a phrase can't be interpreted, looper says so and
changes nothing — fall back to cron.

## Removing unmanaged ("foreign") jobs

`ls` shows every job, including ones looper doesn't manage. Those get a stable
handle `f1`, `f2`, … in the ID column:

```
ID            SCHEDULE              NEXT RUN          COMMAND
f1            @reboot               at boot           ? /opt/legacy/warmup.sh
report        0 8 * * 1-5           2026-05-22 08:00  ● /usr/local/bin/report.sh
```

Remove a managed job by its id, an unmanaged one by its handle, or several at
once — each is backed up and confirmed first:

```sh
looper rm report          # a managed job, by id
looper rm f1              # an unmanaged job, by its ls handle
looper rm report f1       # both at once
```

`import` instead adopts unmanaged jobs into looper (giving them ids) rather than
removing them.

## For agents

If you're an agent calling looper, the relevant primitives are:

```sh
# Stamp every job you create so you can find it again
export LOOPER_AS=agent-a       # or pass --as agent-a per call

# Install a recurring job — wraps by default, so cron's output is captured
looper add --id job-1 "@hourly" "/opt/bin/poll.sh"

# Talk to looper in JSON — auto-enabled because stdout is piped
looper ls --owner agent-a | jq '.jobs[].id'

# Read what your jobs did
looper history job-1 | jq '.runs[0]'      # most recent run, full record
looper last job-1    | jq '.exit_code'    # quick check

# Find every record this agent ever produced
looper runs ls --owner agent-a | jq '.runs[]'

# Read captured stdout/stderr from a specific run
looper runs show <run_id> | jq '.captured.stdout'
```

The full v0.1 agent-loop contract lives in [scripts/acceptance-v0.1.sh](scripts/acceptance-v0.1.sh)
— exit 0 means looper is shippable as an agent primitive. The JSON envelope
shapes are documented in [docs/JSON_SCHEMA.md](docs/JSON_SCHEMA.md).

## How it stores jobs

A managed job is two lines in the crontab — a marker plus the real cron line.
Under wrap-by-default, the cron line invokes the internal `_exec` wrapper so
every fire produces a captured run record:

```
#looper# id=db-backup enabled=1 capture=1 wrapper_bin=/usr/local/bin/looper created_by=agent-a created_at=1779697144 last_modified_by=agent-a last_modified_at=1779697144
0 3 * * * /usr/local/bin/looper _exec --source-id=db-backup --owner=agent-a -- /bin/sh -c '/usr/local/bin/backup.sh --db'
```

The legacy bare-cron shape is still available with `--no-wrap`:

```
#looper# id=db-backup enabled=1
0 3 * * * /usr/local/bin/backup.sh --db
```

Disabled, the payload is commented so cron ignores it but the definition
survives:

```
#looper# id=db-backup enabled=0
# 0 3 * * * /usr/local/bin/backup.sh --db
```

Anything without a `#looper#` marker — your environment lines (`PATH=`,
`MAILTO=`), comments, and hand-written jobs — is preserved untouched and shown
in `ls` as unmanaged (`·`). `looper import` adopts those into management.

## Backups

Before every change, the current crontab is snapshotted to:

```
${XDG_STATE_HOME:-~/.local/state}/looper/backups/<target>/<UTC-timestamp>.crontab
```

Snapshots are managed with three verbs:

```sh
looper backups                       # list newest-first: stamp, size, age
looper restore                       # roll back to the newest snapshot
looper restore --from 20260521       # roll back to a specific snapshot
                                     #   (full stamp OR unambiguous substring)
looper backups prune --keep 20       # keep the newest 20, remove the rest
```

`restore` is itself a mutation, so it auto-backs-up first — nothing is ever
unrecoverable. `prune` will refuse `--keep 0` (it would wipe every snapshot)
and prompts for confirmation unless run with `--yes`; pair with `--dry-run`
to preview the exact list of stamps that would be removed.

`--from` accepts the full 16-char stamp (`20260521T180000Z`) or any
unambiguous substring (`20260521`). If a substring matches more than one
snapshot, looper refuses rather than silently picking one — run `looper
backups` and narrow the input.

## One-shots and captured runs

Two features let you reach for looper for work that isn't strictly "a recurring
cron line": deferred one-shots, and durable record-keeping of any job's output.

### `looper once <when> <command>`

Schedule a single firing at the moment you describe — in cron, in English (via
Kairoz), or absolute. Looper writes a normal cron line under the hood and
arranges for the job to self-remove from the crontab after it fires:

```sh
looper once "in 5 min" "/opt/bin/backup.sh"
looper once "tomorrow at 8am" "report.sh"
looper once "2026-06-01 09:00" "rollover.sh"
```

The job runs through the same `_exec` wrapper that `--capture` uses, so stdout,
stderr, exit code, and timing are all captured to the runs store automatically.
v1 is local-target only; remote one-shots add per-target wrapper resolution
issues that are tracked separately.

### `looper add <schedule> <command>` (wraps by default)

Every `add` wraps the cron payload through the internal `_exec` subcommand
before writing it. Each fire records a `RunRecord` under
`${XDG_STATE_HOME:-~/.local/state}/looper/runs/<run_id>/`:

```
meta — newline key=value lines: source_id, started_at, finished_at, exit_code, timed_out, created_by
out  — the run's captured stdout
err  — the run's captured stderr
```

Pass `--no-wrap` to opt out and produce a bare cron line — useful for jobs you
deliberately want to behave like classic cron (silent on success, mail-on-output).
Capture is sticky on update: re-adding the same id without `--no-wrap` keeps
the wrap. To remove capture, `rm` the job and re-add it with `--no-wrap`.

### `looper history <id>` / `looper last <id>`

Read the runs your jobs have produced. Both query the local runs store filtered
by `source_id`:

```sh
looper history db-backup                    # newest-first list of past runs
looper last db-backup                       # the most recent run record
looper history db-backup | jq '.runs[0]'    # JSON for piping
```

`history` returns the full list under `runs: [...]`; `last` returns the most
recent record at the top level. Both exit `1` when no records match an id.

### `looper runs ls / show / prune`

```sh
looper runs ls                              # newest first: id, status, age, command
looper runs ls --status failed              # filter by lifecycle state
looper runs show <run_id>                   # meta + first 8KB of out/err inline
looper runs show <run_id> --full            # uncapped — pipe to less or a file
looper runs prune --older-than 2592000      # remove records older than 30 days
```

The runs store is per-machine local state — there's no `-H host` concept on
the `runs` family. The runs CLI also synthesizes a "pending" entry for any
one-shot whose crontab marker exists but hasn't fired yet, so you can see
what's queued alongside what already ran.

## `--all` host list

`~/.config/looper/hosts`, one host per line, `#` for comments:

```
pi@nas
pi@media
deploy@web1
```

## Timezones

For a cross-timezone fleet, "next run at 03:00" is meaningless without saying
*whose* clock that is. looper resolves the target's timezone on every read and
labels every wall-clock string accordingly.

```
$ looper -H sg-host show db-backup
db-backup  enabled
  schedule : 0 3 * * *
  meaning  : at 03:00 every day
  command  : /usr/local/bin/backup.sh
  target   : sg-host
  timezone : SGT (UTC+08:00, probed from target)
  next 5   :
    2026-05-22 03:00 SGT  in 12h 27m
    2026-05-23 03:00 SGT  in 1d 12h
    ...
```

**How it works.** For each remote target, the same ssh round-trip that runs
`crontab -l` also runs `date +%z` / `date +%Z`. The result is split on a
sentinel and parsed into the target's offset and abbreviation. **Zero extra
ssh round-trips** — `looper --all ls` against twenty hosts is exactly as fast
as before, and times now render in each host's own clock.

When the probe fails (restricted shell, exotic `date` output, locale-translated
`%Z`), looper falls back to the controller's timezone and tags every line
`(controller-local)` so you're never silently misled.

**Caveat: snapshot offset, not zoneinfo.** The probe gives a fixed offset
("`SGT` is currently UTC+08:00"), not the target's full DST rules. If a target
zone has a DST transition during the next-5 horizon shown by `show`, entries
past the boundary will be off by an hour. The cron daemon on the target is the
source of truth; looper only previews. Shipping a zoneinfo database would add
~3MB to the binary and break libc-only, so the snapshot is a deliberate
tradeoff.

Use `--no-target-tz` to skip probing entirely and force controller-local
labeling — handy for scripted consumers that want a stable rendering, or for
targets with a deliberately broken `date` binary. `doctor` reports the probed
TZ for each remote target so you can verify it once and forget it.

## JSON output

JSON is the auto-default whenever stdout is not a TTY — piping to `jq`, capturing
to a file, or calling looper from an agent all enable it without `--json`. Pass
`--json` explicitly when you need it on a TTY. Flag position is free.

Every JSON document carries a `schema_version` field (currently `1`) and uses an
envelope shape — `ls` and `runs ls` wrap their arrays under a key so future
additions stay non-breaking. Field names are snake_case; missing values are
`null` (never `0`, never `""`). The full contract lives in
[docs/JSON_SCHEMA.md](docs/JSON_SCHEMA.md).

**`ls`** — `{schema_version, target, jobs: [...]}`:

```json
{
  "schema_version": 1,
  "target": "sg-host",
  "jobs": [{
    "id": "db-backup",
    "enabled": true,
    "foreign": false,
    "target": "sg-host",
    "schedule": "0 3 * * *",
    "human_schedule": "at 03:00 every day",
    "command": "/usr/local/bin/backup.sh --db",
    "tz": "SGT",
    "tz_offset_secs": 28800,
    "tz_source": "target_probed",
    "created_by": "agent-a",
    "created_at": 1779697144,
    "last_modified_by": "agent-a",
    "last_modified_at": 1779697144,
    "next": 1779438000,
    "next_human": "2026-05-22 03:00 SGT  in 12h 27m"
  }]
}
```

`next` is **`null`** (not `0`) when the schedule doesn't parse or has no next
fire (e.g., `@reboot`); `next_human` mirrors that. `tz_source` is one of
`controller_local`, `target_probed`, or `controller_fallback`. Provenance fields
are `null` for legacy jobs added before v0.1 (or via `--no-wrap` without `--as`).

**`show`** — single object with the same per-job fields as `ls`, plus
`schema_version`, `reboot`, and `next` as an array of `{epoch, human}` pairs
covering the next 5 fires (empty for `@reboot`, `null` for unparseable schedules
with an additional `parse_error` field).

**`runs ls`** — `{schema_version, runs: [...]}`. Each record carries `run_id`,
`status` (`pending`/`running`/`done`/`failed`), `source_id`, `command`,
`target_label`, `once`, `scheduled_for`, `started_at`, `finished_at`,
`exit_code`, `timed_out`, and `created_by`.

**`runs show <run_id>`** — single record (same shape as above) plus a
`captured` object:

```json
{
  "schema_version": 1,
  "run_id": "rec-6a14a88a-97053-0",
  "status": "done",
  "source_id": "rec",
  "exit_code": 0,
  "created_by": "agent-a",
  "captured": {
    "stdout": "hello\n",
    "stdout_total_bytes": 6,
    "stdout_truncated": false,
    "stderr": "",
    "stderr_total_bytes": 0,
    "stderr_truncated": false
  }
}
```

Pass `--full` to lift the 8 KiB inline cap on stdout/stderr.

**`history <id>`** — `{schema_version, id, runs: [...]}` with the same record
shape as `runs ls`.

**`last <id>`** — single record at the top level (with `schema_version` + `id`
alongside); `{"run": null, "id": "...", "schema_version": 1}` and exit 1 when
no records match.

**`explain`** — single object: `schema_version`, `input`, resolved `schedule`,
`human_schedule`, `interpreted` (true if NLP rewrote the input), `reboot`, `tz`,
`tz_offset_secs`, and `next` (array of `{epoch, human}` pairs).

**`--dry-run` with a mutation** — single object:

```json
{
  "dry_run": true,
  "target": "file:/tmp/c",
  "action": "edited 'db-backup'",
  "changed": true,
  "diff": [
    {"op": "context", "line": "#looper# id=db-backup enabled=1"},
    {"op": "remove",  "line": "0 3 * * * /bin/x"},
    {"op": "add",     "line": "0 4 * * * /bin/x"}
  ]
}
```

A no-op dry-run yields `"changed": false` with `"diff": []` so consumers can
distinguish "ran with no work to do" from "errored."

Multi-target invocations emit one JSON document per target. The
human-readable `=== host ===` headers are suppressed under `--json` so the
output stays parseable; each document carries its own `target` field so hosts
are disambiguated.

## Notes & limits

- **Scope is deliberate.** looper only emits standard cron. If an expression
  isn't valid cron, it's rejected — the tool won't paper over cron's own rules.
- **`@reboot`** is supported as a literal; there's no "next run" to compute for it.
- **Exit codes:** `0` success, `1` operational error (job not found, write
  failed, bad schedule), `2` usage error. `run` propagates the job's own exit code.
- Honors `NO_COLOR`, `--no-color`, and non-tty output (color off automatically).

## Building & testing

The codebase is organized under `src/` with three subdirectories:

- `src/cron/` — schedule parser, next-run calculators (controller-zone and
  target-zone), humanizer, NLP front-end, English-time parser for `once`
- `src/crontab/` — file model with the `_exec` wrapper synthesizer, target
  backends (local/ssh/file), backup snapshots, sentinel-split crontab+TZ
  reader, and the run-record store
- `src/commands/` — one file per command family (mutate / view / runs / exec
  / history / once / backup / doctor / preflight / core); `commands.zig` is
  the re-export façade
- `src/ui/` — terminal display, diff renderer, help screen

Plus `src/tz.zig` (pure TzInfo + probe parser) and `src/tz_probe.zig` (the
ssh-side TZ probe + per-run cache). See [CLAUDE.md](CLAUDE.md) for the full
per-file map and the architectural invariants the codebase preserves.

Inline unit tests are colocated with each module (the schedule parser, both
next-run calculators, the Vixie DOM/DOW OR-rule, the timezone probe parser,
the CLI flag validation, the marker round-trips, the runs store, etc.). Run
them with:

```sh
make test                # zig build test — 300+ inline tests
make itest               # end-to-end script against /tmp/looper-itest-$$
```

The v0.1 acceptance script exercises the full agent-loop contract — install,
own, run, observe — end-to-end:

```sh
bash scripts/acceptance-v0.1.sh
```

Each subsequent milestone has its own acceptance script (`acceptance-v0.2.sh`
through `acceptance-v0.7.sh`) that defines what "done" looks like for that
milestone, executable.

## Status & roadmap

Looper is in active development. The shipped surface above covers the human-CLI
use case (managing cron on one box or a fleet, with deferred one-shots and
durable output capture) **plus the v0.1 agent-loop milestone** — wrap-by-default
execution, provenance per job, JSON-first output with stable `schema_version`,
and the `history`/`last` read side of the feedback loop. An agent can install a
job, claim it via `--as`, fire it manually with `looper run`, and read what it
produced — all through stable JSON. The contract is captured executably in
[`scripts/acceptance-v0.1.sh`](scripts/acceptance-v0.1.sh) and the JSON shapes
in [`docs/JSON_SCHEMA.md`](docs/JSON_SCHEMA.md).

Next milestones (v0.2–v0.7) layer in declarative `apply`, parallel ssh fan-out,
drift detection, end-to-end verification, push subscriptions, structured run
queries, Prometheus metrics, hooks, audit logging, catchup, per-owner quotas,
ergonomics (`tui`, completions), and an MCP server surface. See
[ROADMAP.md](ROADMAP.md) for the full breakdown. Live status:
[GitHub milestones](https://github.com/AnthemFlynn/looper/milestones).

This direction does not widen looper's scope. Looper stays a cron
management tool — never a scheduler, never a daemon, never a workflow
engine. Dependency graphs, retry policies, alerting transports, and
persistent supervision are explicitly out of scope.

## License

MIT — see [LICENSE](LICENSE).
