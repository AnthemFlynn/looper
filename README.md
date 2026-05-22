# looper

A sharp little CLI that manages one-to-many cron jobs — locally, for another
user, across remote hosts over **ssh**, or in a plain crontab file. One job,
done well: **manage cron jobs**. It speaks standard 5-field cron plus the
`@macros` cron already understands; it never invents a scheduler syntax.

Modular Zig 0.16 codebase under `src/` (~1100 lines total), no dependencies
beyond libc, static binaries for every box in a mixed-arch fleet.

```
$ looper ls
ID            SCHEDULE              NEXT RUN                   COMMAND
db-backup     0 3 * * *             2026-05-22 03:00  in 1h 14m ● /usr/local/bin/backup.sh --db
tidy          */15 9-17 * * mon-fri 2026-05-22 09:00  in 7h 14m ● tidy-temp
warmup        @reboot               at boot                  ○ /opt/legacy/warmup.sh
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
  backup / restore [file]  snapshot / roll back (restore also auto-backs-up)
  version | help

Target (default: your local crontab)
  -H, --host <[user@]host> remote host via ssh (repeatable)
      --all                every host listed in ~/.config/looper/hosts
  -u, --user <user>        another user's crontab (crontab -u)
  -f, --file <path>        a plain crontab file (great for git-tracked crontabs)

Options
      --dry-run            show the diff that would be written; write nothing
  -y, --yes                assume yes (required for destructive ops without a tty)
      --json               machine-readable output (ls)
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

`looper restore` rolls back to the newest snapshot (or a path you name) — and
because restore is itself a mutation, it backs up first too. Nothing is ever
unrecoverable.

## `--all` host list

`~/.config/looper/hosts`, one host per line, `#` for comments:

```
pi@nas
pi@media
deploy@web1
```

## Notes & limits

- **Scope is deliberate.** looper only emits standard cron. If an expression
  isn't valid cron, it's rejected — the tool won't paper over cron's own rules.
- **`@reboot`** is supported as a literal; there's no "next run" to compute for it.
- **Remote next-run times** are computed in the *controlling* machine's
  timezone. For a single-timezone homelab that's correct; across timezones,
  read them as "controller local".
- **Exit codes:** `0` success, `1` operational error (job not found, write
  failed, bad schedule), `2` usage error. `run` propagates the job's own exit code.
- Honors `NO_COLOR`, `--no-color`, and non-tty output (color off automatically).

## Building & testing

The codebase is organized under `src/` with three subdirectories:

- `src/cron/` — schedule parser, next-run calculator, humanizer, NLP front-end
- `src/crontab/` — file model, target backends (local/ssh/file), backup snapshots
- `src/ui/` — terminal display, diff renderer, help screen

The schedule parser, next-run calculator (DST-correct via libc `localtime_r`/
`mktime`), and the Vixie DOM/DOW OR-rule are covered by inline unit tests
colocated with each module. Run them with:

```sh
zig build test
```

## License

MIT — see [LICENSE](LICENSE).
