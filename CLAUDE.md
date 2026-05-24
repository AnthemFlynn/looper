# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`looper` is a Zig 0.16 CLI that manages cron jobs — locally, for another user, on remote hosts over `ssh`, or in a plain crontab file. The source lives under `src/`, libc-only, no third-party dependencies. Built with `build.zig` (`zig build`); cross-targets are passed via `-Dtarget=...`.

## Direction

Active product direction: looper as an automation primitive for agents, not just a human CLI. Concretely: JSON-first output, provenance per job (`created_by`, `last_modified_by`), wrap-by-default execution (promoting the existing `--capture` to the default), end-to-end verification, and declarative apply. See [ROADMAP.md](ROADMAP.md) for the v0.1–v0.4 milestone breakdown and the GitHub issues linked from each section.

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
  ctx.zig                 Ctx struct (allocator, flags, output buffer, exit_code accumulator), aw helper
  posix.zig               Single @cImport for libc; runCapture / runInherit / writeAll / getenv / nowEpoch
  tz.zig                  Pure TzInfo {offset_secs, abbrev, source}; controllerTz, parseDateProbe
  tz_probe.zig            Remote-side ssh TZ probe + per-run Cache; pairs with tz.zig
  commands.zig            Thin re-export façade over commands/* (preserves the import path main.zig uses)
  commands/
    core.zig              applyMutation funnel + nextFor (TZ-aware next-run dispatch)
    mutate.zig            cmdAdd / cmdEdit / cmdRm / cmdToggle (enable / disable)
    view.zig              cmdLs / cmdShow / cmdRun / cmdExplain
    backup.zig            cmdBackup / cmdBackups / cmdBackupsPrune / cmdRestore / cmdImport
    doctor.zig            cmdDoctor + dirWritable / fileReadable / sshReachable
    preflight.zig         --check-command surface: extractBinary + commandReachable + hasInPath
  cron/
    schedule.zig          Schedule bitset + parseSchedule + fieldBounds + parseField + nameToNum
    next_run.zig          nextRun (controller-zone, DST-correct) + nextRunInTz (fixed-offset target zone)
    humanize.zig          Cron expression → English; relTime, fmtWhen, fmtWhenIn (renders in TzInfo)
    nlp.zig               English → standard cron via nlpToCron / toCron front-end
  crontab/
    model.zig             MARKER, Job, Item, Crontab, parseCrontab, serialize, splitScheduleCommand
    target.zig            Target/TargetKind + readCrontab/writeCrontab + readCrontabAndTz (sentinel-split)
    backup.zig            doBackup, newestBackup, listBackups, findByStamp, pruneBackups, stateDir, backupDir, utcStamp, mkdirP
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
- **`--json` is a stable contract.** Field names use snake_case; missing values are `null` (never `0`, never `""`); `tz_source` uses the canonical names from `tz.sourceStr` rather than `@tagName` so refactors don't break consumers. Multi-target JSON emits one document per target with each carrying its own `target` field — the `=== host ===` headers are suppressed under `--json`. Diff ops use `"context"`/`"remove"`/`"add"` from `diff.opName`. Adding fields is fine; renaming or removing is a breaking change.
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
# Roundtrip without touching the system crontab
zig build run -- -f /tmp/test.crontab add --id demo "every weekday at 8am" "echo hi"
zig build run -- -f /tmp/test.crontab ls
zig build run -- -f /tmp/test.crontab show demo
zig build run -- -f /tmp/test.crontab --dry-run rm demo

# Pure parser exercise — writes nothing
zig build run -- explain "*/15 9-17 * * mon-fri"
zig build run -- explain "every 15 min from 9am to 5pm on weekdays"

# Preflight — checks binaries, backup dir, hosts file, and per-target reach
zig build run -- doctor
zig build run -- -H some.host doctor
zig build run -- --all doctor
```
