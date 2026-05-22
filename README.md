# looper

A sharp little CLI that manages one-to-many cron jobs — locally, for another
user, across remote hosts over **ssh**, or in a plain crontab file. One job,
done well: **manage cron jobs**. It speaks standard 5-field cron plus the
`@macros` cron already understands; it never invents a scheduler syntax.

Modular Zig 0.16 codebase under `src/` (~1900 lines total), no dependencies
beyond libc, static binaries for every box in a mixed-arch fleet.

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

Build it with Zig 0.16+ (only libc is needed):

```sh
zig build -Doptimize=ReleaseSafe
install -m755 zig-out/bin/looper ~/.local/bin/looper
```

Or use a prebuilt binary from this folder:

- `looper` — native Linux x86_64 (stripped, 376K)
- `looper-x86_64-linux-musl` — fully static, any x86_64 Linux/container
- `looper-aarch64-linux-musl` — fully static, Raspberry Pi / ARM Linux
- `looper-aarch64-macos` — Apple Silicon (Mac mini M-series)

### Cross-compiling for a whole fleet

Zig cross-compiles from any host. To rebuild every target:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
```

The `*-linux-musl` builds are statically linked — copy them to a Pi and run,
no runtime, no libc version to match.

## Usage

```
looper <command> [args] [options]

Commands
  ls                       list jobs (managed + unmanaged) with next run times
  add <schedule> <cmd>     add or update a job (idempotent; --id to name it)
  rm <id|fN>...            remove job(s) by id, or unmanaged ones by fN handle
  enable / disable <id...> toggle a job without deleting its definition
  show <id>                detail: meaning + next 5 run times
  run <id>                 run a job's command right now (streamed output)
  explain <schedule>       explain a cron expression + next runs (writes nothing)
  import                   adopt existing unmanaged jobs into looper
  backup                   snapshot the current crontab
  backups                  list snapshots (newest first; size + age)
  backups prune --keep N   remove older snapshots, keep the newest N
  restore [file|--from S]  roll back to the newest, a named file, or a stamp
  version | help

Target (default: your local crontab)
  -H, --host <[user@]host> remote host via ssh (repeatable)
      --all                every host listed in ~/.config/looper/hosts
  -u, --user <user>        another user's crontab (crontab -u)
  -f, --file <path>        a plain crontab file (great for git-tracked crontabs)

Options
      --dry-run            show the diff that would be written; write nothing
  -y, --yes                assume yes (required for destructive ops without a tty)
      --json               machine-readable output (ls, show, explain, dry-run)
  -q, --quiet              only print errors
      --no-color           disable color (also honored: NO_COLOR)
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

## How it stores jobs

A managed job is two lines in the crontab — a marker plus the real cron line:

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

`--json` produces machine-readable output for `ls`, `show`, `explain`, and
`--dry-run` mutations. Flag position is free — `looper show db-backup --json`,
`looper --json show db-backup`, and any other interleaving produce the same
output. Multi-target invocations emit one JSON document per target (one `ls`
array per host, one `show` object per host, etc.) — the human-readable
`=== host ===` headers are suppressed under `--json` so the output stays
parseable. Every document carries its own `target` field so the hosts are
disambiguated.

**`ls`** — array of jobs:

```json
[{
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
  "next": 1779438000,
  "next_human": "2026-05-22 03:00 SGT  in 12h 27m"
}]
```

`next` is **`null`** (not `0`) when the schedule doesn't parse or has no next
fire (e.g., `@reboot`); `next_human` mirrors that. `tz_source` is one of
`controller_local`, `target_probed`, or `controller_fallback`.

**`show`** — single object, with `next` as an array of `{epoch, human}` pairs
covering the next 5 fires (empty for `@reboot`, `null` for unparseable schedules
with an additional `parse_error` field).

**`explain`** — single object: `input`, resolved `schedule`, `human_schedule`,
`interpreted` (true if NLP rewrote the input), `reboot`, `tz`, `tz_offset_secs`,
and `next` (same shape as `show`).

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
  target-zone), humanizer, NLP front-end
- `src/crontab/` — file model, target backends (local/ssh/file), backup
  snapshots, sentinel-split crontab+TZ reader
- `src/ui/` — terminal display, diff renderer, help screen

Plus `src/tz.zig` (pure TzInfo + probe parser) and `src/tz_probe.zig` (the
ssh-side TZ probe + per-run cache).

The schedule parser, both next-run calculators (DST-correct via libc
`localtime_r`/`mktime` for controller-zone; fixed-offset via `gmtime_r`/`timegm`
for target-zone), the Vixie DOM/DOW OR-rule, and the timezone probe parser
are all covered by inline unit tests colocated with each module. Run them with:

```sh
zig build test
```

## License

MIT — see [LICENSE](LICENSE).
