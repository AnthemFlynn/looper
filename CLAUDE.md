# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`looper` is a Zig 0.16 CLI that manages cron jobs — locally, for another user, on remote hosts over `ssh`, or in a plain crontab file. The source lives under `src/`, libc-only, no third-party dependencies. Built with `build.zig` (`zig build`); cross-targets are passed via `-Dtarget=...`.

## Direction

Active product direction: looper as an automation primitive for agents, not just a human CLI. The v0.1 agent-loop milestone has shipped — provenance per job (`created_by`/`created_at`/`last_modified_by`/`last_modified_at`), wrap-by-default execution (the `_exec` wrapper produces a captured run record per fire), JSON-first output (auto-enabled on non-TTY stdout, every document carries `schema_version: 1`), and the `history` / `last` read side of the agent feedback loop. See [ROADMAP.md](ROADMAP.md) for the v0.2–v0.7 milestones still ahead and the GitHub issues linked from each section.

This direction does **not** widen looper's scope. The codebase stays a cron management tool — never a scheduler, never a daemon, never a workflow engine. The added surface (provenance, wrap defaults, verify, apply) makes the same managed-cron job safer and more programmable; it does not introduce job dependency graphs, persistent supervision, or alerting transports.

When implementing features from the roadmap, prefer extending the existing primitives (the `#looper#` marker schema, the `_exec` wrapper, the `applyMutation` funnel, the runs store) rather than adding parallel mechanisms. The agent-primitive features should feel like the natural next layer on top of the human-CLI foundation, not a separate product bolted on.

## Build & run

```sh
zig build                                          # debug build → zig-out/bin/looper
zig build -Doptimize=ReleaseSafe                   # native release
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos

zig build test                                     # run all inline tests
zig build run -- -f /tmp/test.crontab ls           # run with args
```

## Source layout

```
src/
  main.zig                Entry point: Cmd enum + parseCmd; orchestrates argv→cli→targets→dispatch
  cli.zig                 Pure argv parser (ParsedArgs) and target-list builder; all tested in isolation
                          Also: isValidPrincipal (whitespace/=/control-byte guard for --as / --owner values)
  ctx.zig                 Ctx struct (allocator, flags, output buffer, exit_code accumulator), aw helper
  posix.zig               Single @cImport for libc; runCapture / runInherit / writeAll / getenv / nowEpoch
                          / looperPath (per-platform self-path) / shellQuote / shellUnquote
  tz.zig                  Pure TzInfo {offset_secs, abbrev, source}; controllerTz, parseDateProbe
  tz_probe.zig            Remote-side ssh TZ probe + per-run Cache; pairs with tz.zig
  commands.zig            Thin re-export façade over commands/* (preserves the import path main.zig uses)
  commands/
    core.zig              applyMutation funnel + nextFor (TZ-aware next-run dispatch)
    mutate.zig            cmdAdd / cmdEdit (with EditOpts) / cmdRm / cmdToggle (enable / disable);
                          AddOpts owns wrap-by-default flag, --as plumbing, --check-command toggle
    view.zig              cmdLs (LsOpts.owner filter) / cmdShow / cmdRun / cmdExplain;
                          cmdRun routes local+file targets through cmdExecWithOwner so manual runs
                          produce a run record. JSON envelopes carry schema_version + provenance.
    backup.zig            cmdBackup / cmdBackups / cmdBackupsPrune / cmdRestore / cmdImport
    doctor.zig            cmdDoctor + dirWritable / fileReadable / sshReachable
    preflight.zig         --check-command surface: extractBinary + commandReachable + hasInPath
    exec.zig              cmdExec / cmdExecWithOwner — the cron-invoked wrapper that captures
                          stdout/stderr, writes the run record, and (if --once) self-removes the
                          source job via applyMutation. Auto-synthesizes run_id when absent and
                          --source-id is present (cron-fired recurring captured path).
    once.zig              cmdScheduleOnce + OnceOpts — `looper once <when> <cmd>` writes a one-shot
                          wrapper line via Kairoz/once_when time parsing
    runs.zig              cmdRunsLs (Filter.status / Filter.owner) / cmdRunsShow / cmdRunsPrune;
                          synthesizes pending records from one-shot markers not yet fired
    history.zig           cmdHistory / cmdLast — read run records filtered by source_id; the
                          agent's read side of the feedback loop. State-dir-local, no target loop.
  cron/
    schedule.zig          Schedule bitset + parseSchedule + fieldBounds + parseField + nameToNum
    next_run.zig          nextRun (controller-zone, DST-correct) + nextRunInTz (fixed-offset target zone)
    humanize.zig          Cron expression → English; relTime, fmtWhen, fmtWhenIn (renders in TzInfo)
    nlp.zig               English → standard cron via nlpToCron / toCron front-end
    once_when.zig         English/ISO time → epoch for `looper once`; pure, no I/O
  crontab/
    model.zig             MARKER, Job, Item, Crontab, parseCrontab, serialize, splitScheduleCommand,
                          wrapCommand (emits `_exec --source-id=… [--once] [--run-id=…]
                          [--timeout-secs=…] [--owner=…] -- /bin/sh -c '<inner>'`),
                          tryUnwrapInner, provenance attributes round-trip through Marker
    target.zig            Target/TargetKind + readCrontab/writeCrontab + readCrontabAndTz (sentinel-split)
    backup.zig            doBackup, newestBackup, listBackups, findByStamp, pruneBackups, stateDir,
                          backupDir, utcStamp, mkdirP
    runs.zig              RunRecord (incl. created_by) + metaSerialize/metaParse / metaRead/metaWrite
                          / listRuns / pruneRuns; the on-disk format under state_dir/runs/<run_id>/
  ui/
    colors.zig            ANSI escape constants (BOLD/DIM/RED/…); consumed via ctx.k(CODE)
    display.zig           padTo, truncEllipsis, jsonEsc, termWidth, slugFromCommand, confirm
    diff.zig              LCS-based printDiff for --dry-run
    help.zig              printHelp + VERSION
```

The three subdirectories carve the codebase along its three real concerns: `cron/` is pure computation (no I/O), `crontab/` is the storage layer, `ui/` is presentation. Everything else sits at the `src/` root.

## Tests

Inline `test "..." { ... }` blocks colocated at the bottom of each module. `zig build test` discovers them via the import graph from `src/main.zig`. **Note (during the active refactor):** tests are being introduced in stages — commit 2 of the refactor adds the regression net, commit 3 adds new tests for each bug fix.

## Architectural rules to preserve

- **Never emit non-standard cron.** `parseSchedule` validates before any write. If `nlpToCron` returns null for an English phrase, surface the failure — do not invent syntax.
- **Every mutation is preceded by a backup.** `applyMutation` in `commands/core.zig` is the single funnel; new commands that change the crontab must route through it.
- **Managed jobs are identified solely by the `#looper#` marker line.** Lines without that marker are "foreign" and must be preserved untouched on serialize. `import` is the only path that adopts them.
- **Idempotency by `id`.** `add` with an existing id updates in place (full re-statement of schedule + command); never appends a duplicate. For changing only one field — schedule OR command — use `edit <id> --schedule X` / `--command Y` so the unchanged field can't drift.
- **`set` aliases `edit`, not `add`.** Historical: `set` was an undocumented alias for `add`. Reassigned because the natural reading of "set the schedule of X" is the partial-update semantics, which is also less error-prone (no re-statement of the other field).
- **`--json` is a stable contract.** Field names use snake_case; missing values are `null` (never `0`, never `""`); `tz_source` uses the canonical names from `tz.sourceStr` rather than `@tagName` so refactors don't break consumers. Multi-target JSON emits one document per target with each carrying its own `target` field — the `=== host ===` headers are suppressed under `--json`. Diff ops use `"context"`/`"remove"`/`"add"` from `diff.opName`. Adding fields is fine; renaming or removing is a breaking change. **JSON auto-enables when stdout is not a TTY** (the "JSON-first" rule, v0.1) — agents never have to remember `--json`. **Every JSON document carries `schema_version` (currently `1`)** and uses an envelope shape: `ls` → `{schema_version, target, jobs: [...]}`, `runs ls` → `{schema_version, runs: [...]}`, `history` → `{schema_version, id, runs: [...]}`, `runs show` nests captured output under `{... "captured": {"stdout", "stdout_total_bytes", "stdout_truncated", "stderr", "stderr_total_bytes", "stderr_truncated"}}`. See [docs/JSON_SCHEMA.md](docs/JSON_SCHEMA.md) for the full contract. Adding a new envelope key is non-breaking; reshuffling existing keys bumps `schema_version`.
- **Provenance is first-class on every managed job.** Marker attributes: `created_by`, `created_at`, `last_modified_by`, `last_modified_at`. `cmdAdd` stamps both `created_by` and `last_modified_by` when `--as` is supplied (or `LOOPER_AS` env via `main.zig`'s fallback); `cmdEdit` stamps `last_modified_by` + `last_modified_at` and backfills `created_by`/`created_at` when null (legacy job, first edit). Provenance survives serialize/parse round-trips and is emitted in `ls`/`show`/`runs ls`/`runs show`/`history`/`last` JSON. The `RunRecord` also carries `created_by`, copied from the source job at run time, so `runs ls --owner` works for both manual (`looper run`) and cron-fired paths.
- **Principal values are whitespace-free.** `cli.isValidPrincipal` rejects whitespace, `=`, and control bytes for `--as` and `--owner`. Reason: the marker line is whitespace-tokenized on parse, so an unescaped space would silently truncate the value. The same predicate guards the `LOOPER_AS` env path in `main.zig`. Other potentially-spaced fields (`wrapper_bin`, `run_id`) are programmatic, not user-supplied, so this CLI-ingress check is sufficient — the marker format itself stays whitespace-delimited.
- **`add` wraps by default; `--no-wrap` is the escape hatch.** `cmdAdd` resolves `posix.looperPath` and emits a cron payload like `<wrapper_bin> _exec --source-id=<id> [--owner=<created_by>] -- /bin/sh -c '<inner>'`. Wrap-by-default makes silent cron failure detectable: every fire writes a run record under `$XDG_STATE_HOME/looper/runs/<run_id>/`. The legacy `--capture` flag is kept as an explicit synonym; `--no-wrap` produces a bare cron line for callers who genuinely don't want capture. Capture is sticky on update — re-adding the same id without `--no-wrap` keeps `capture=1`; to remove capture, `rm` then re-add with `--no-wrap`.
- **`--owner` carries two disjoint semantics, picked by command.** In `ls` / `runs ls` it's a *filter* (match `created_by`). In `_exec` it's the *stamped principal* the cron-fired run will record (sourced from the wrapper line, which `wrapCommand` emits as `--owner=<created_by>` when set). Same flag, no conflict because the commands are disjoint. Both forms are validated through `isValidPrincipal`.
- **`_exec` synthesizes a fresh run_id when absent and `--source-id` is present.** Cron fires the wrapper line with no `--run-id` for recurring captured jobs (the marker's `run_id` is the "series anchor" for one-shots only). Format: `<source>-<epoch-hex>-<pid>-<counter>`. PID disambiguates same-second fires across cron processes; the atomic counter handles intra-process repeats. Empty run_id + null source_id is still a hard error — there's no anchor to derive from.
- **`history` and `last` are local-only state-dir queries.** No target loop, no crontab read. They filter `listRuns` by `source_id == id` and sort newest-first. `history` returns the full list under `runs: [...]`; `last` returns the most recent record at the top level (with `run: null` + exit 1 when no records match).
- **`run` for local/file targets produces a run record.** Routes through `cmdExecWithOwner` with `created_by` copied from the in-memory Job and a `manual-<epoch-hex>-<counter>-<id>` run_id. Remote targets keep the legacy `runInherit` streaming behavior since capturing a remote run to local files makes no sense.
- **No "remove all" command exists, by design.** `crontab -r` is the footgun this tool exists to avoid. The same rule applies to `backups prune`: `--keep 0` is rejected up-front, so a stray flag can't sweep every snapshot. Pruning always confirms (or honors `-y`/`--yes`), and `--dry-run` previews without unlinking.
- **`backup` (singular) creates a snapshot; `backups` (plural) is the inventory.** Lists newest-first by lex-sortable UTC stamp. `backups prune --keep N` removes the rest. `restore --from <stamp>` resolves a full or substring stamp via `findByStamp` and is mutually exclusive with the positional path argument. Substring matches that hit more than one snapshot are an error, not a "pick the first one" — the caller must narrow the input.
- **Disabled jobs keep their definition.** `disable` comments the payload line but leaves the marker (`enabled=0`); do not delete on disable.
- **Color is opt-in to a tty and `NO_COLOR`.** Use `ctx.k(CODE)` rather than hardcoding escape sequences so `--no-color` / `NO_COLOR` keep working.
- **Output goes through `ctx.emit` + `ctx.flush`,** not direct stdio. Errors go through `posix.eprint`. `Ctx.exit_code` + `ctx.fail(code)` accumulate non-fatal failures (first-failure-wins) so a multi-target run still surfaces a non-zero exit.
- **`doctor` owns its own target loop.** It branches before the standard per-target read loop in `main.zig` because the read failures the loop treats as fatal-per-target are exactly what doctor is reporting on. New "diagnostic" commands should follow the same pattern.
- **Timezones flow as values through `cron/`.** The `cron/` subdir stays I/O-free; any function that needs the target's zone takes a `TzInfo` (or just `offset_secs`) parameter. `nextRunInTz` and `fmtWhenIn` are the canonical "operate in a supplied zone" functions. The I/O — the ssh-side `date +%z` probe — lives in `tz_probe.zig` (standalone) and `crontab/target.zig` (piggybacked on `crontab -l` via sentinel split). Never call probing code from `cron/`.
- **`add --check-command` is opt-in, non-blocking, and never writes.** The reachability probe (`extractBinary` + `commandReachable` in `commands/preflight.zig`) runs after schedule validation, before `applyMutation`. A `missing` result yields one yellow `!` line; `found` and `skipped` (file targets, unparseable commands, broken probe) stay silent. The warning is suppressed under `--quiet` and under `--json` (it would corrupt structured stdout). The add proceeds regardless — cron failures are diagnosed, not blocked, so `--check-command` never gets in the user's way. Remote probes use `ssh ... sh -c "command -v -- 'BIN' >/dev/null 2>&1"`; `commandReachable` refuses to probe binary names containing characters outside `[A-Za-z0-9_.+/-]` so a malformed extraction never reaches the shell.

## SOLID lines

- **Backends are a single file with switch dispatch** — `target.zig` handles local/remote/file via a `switch (t.kind)`. No `Backend` trait/vtable for three known compile-time backends. Extract an interface only when a fourth real backend (e.g., Kubernetes CronJob) appears.
- **Commands depend on `applyMutation`, not on `target.zig` directly.** A subcommand never calls `readCrontab` / `writeCrontab` / `doBackup` itself — the mutation funnel owns the read-backup-write sequence.
- **Per-module errors.** No aggregated `errors.zig`; Zig's error union inference handles propagation.

## Targets & invocation model

A single command can run against multiple targets — `-H host` (repeatable), `--all` (reads `~/.config/looper/hosts` or `$XDG_CONFIG_HOME/looper/hosts`), `-u user`, or `-f path`. The main loop iterates targets, prints a `=== label ===` header in multi-target mode, and continues past per-target read failures rather than aborting the batch.

## Zig 0.16 specifics worth knowing

- Entry point is `pub fn main(init: std.process.Init.Minimal) !void` — argv comes from `init.args.toSlice(a)`, not `std.process.argsAlloc`.
- `std.ArrayList(T)` is used in the unmanaged style: `.empty` init, `appendSlice(a, ...)` with an explicit allocator on every call.
- An arena allocator (`std.heap.page_allocator`) backs everything in `main`; individual functions take `std.mem.Allocator` and may leak into the arena freely.
- POSIX calls go through `posix.c.fork` / `posix.c.execvp` / `posix.c.waitpid` rather than `std.process.Child`; keep new subprocess work in that style for consistency.
- `link_libc = true` is set on the module in `build.zig`, not via `linkSystemLibrary`.

## Useful runtime entry points for manual verification

```sh
# Roundtrip without touching the system crontab — wraps by default
zig build run -- -f /tmp/test.crontab add --as agent-a --id demo "every weekday at 8am" "echo hi"
zig build run -- -f /tmp/test.crontab ls
zig build run -- -f /tmp/test.crontab show demo
zig build run -- -f /tmp/test.crontab --dry-run rm demo

# Legacy bare-cron path (the escape hatch)
zig build run -- -f /tmp/test.crontab add --no-wrap --id legacy "@daily" "/bin/true"

# Agent-style: stamp provenance via env, query own jobs only
LOOPER_AS=agent-a zig build run -- -f /tmp/test.crontab add --id rec "@daily" "echo hi"
zig build run -- -f /tmp/test.crontab ls --owner agent-a
zig build run -- -f /tmp/test.crontab ls --owner other       # empty result

# Agent feedback loop: fire a job manually, read what it produced
zig build run -- -f /tmp/test.crontab run demo
zig build run -- -f /tmp/test.crontab history demo
zig build run -- -f /tmp/test.crontab last demo
zig build run -- -f /tmp/test.crontab runs ls --owner agent-a

# JSON is the auto-default off-tty — piping enables it without --json
zig build run -- -f /tmp/test.crontab ls | jq '.schema_version, .jobs[].id'

# Pure parser exercise — writes nothing
zig build run -- explain "*/15 9-17 * * mon-fri"
zig build run -- explain "every 15 min from 9am to 5pm on weekdays"

# Preflight — checks binaries, backup dir, hosts file, and per-target reach
zig build run -- doctor
zig build run -- -H some.host doctor
zig build run -- --all doctor

# v0.1 acceptance — end-to-end agent-loop contract; should exit 0
bash scripts/acceptance-v0.1.sh
```
