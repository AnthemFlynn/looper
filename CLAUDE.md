# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`looper` is a Zig 0.16 CLI that manages cron jobs — locally, for another user, on remote hosts over `ssh`, or in a plain crontab file. The source lives under `src/` (~1100 lines across 11 modules), libc-only, no third-party dependencies. Built with `build.zig` (`zig build`); cross-targets are passed via `-Dtarget=...`.

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
  main.zig                Entry point: argv parsing, target list, per-target dispatch loop
  ctx.zig                 Ctx struct (allocator, flags, output buffer), color constants, g_exit
  posix.zig               Single @cImport for libc; runCapture / runInherit / getenv / nowEpoch
  commands.zig            applyMutation + cmdLs/Add/Rm/Toggle/Show/Run/Explain/Backup/Restore/Import
  cron/
    schedule.zig          Schedule bitset + parseSchedule + fieldBounds + parseField + nameToNum
    next_run.zig          nextRun using DOM/DOW OR-rule; libc localtime_r/mktime for DST
    humanize.zig          Cron expression → English; relTime, fmtWhen
    nlp.zig               English → standard cron via nlpToCron / toCron front-end
  crontab/
    model.zig             MARKER, Job, Item, Crontab, parseCrontab, serialize, splitScheduleCommand
    target.zig            Target/TargetKind + readCrontab/writeCrontab (switch dispatch over 3 backends)
    backup.zig            doBackup, newestBackup, stateDir, backupDir, utcStamp, mkdirP
  ui/
    display.zig           padTo, truncEllipsis, jsonEsc, termWidth, slugFromCommand, confirm
    diff.zig              LCS-based printDiff for --dry-run
    help.zig              printHelp + VERSION
```

The three subdirectories carve the codebase along its three real concerns: `cron/` is pure computation (no I/O), `crontab/` is the storage layer, `ui/` is presentation. Everything else sits at the `src/` root.

## Tests

Inline `test "..." { ... }` blocks colocated at the bottom of each module. `zig build test` discovers them via the import graph from `src/main.zig`. **Note (during the active refactor):** tests are being introduced in stages — commit 2 of the refactor adds the regression net, commit 3 adds new tests for each bug fix.

## Architectural rules to preserve

- **Never emit non-standard cron.** `parseSchedule` validates before any write. If `nlpToCron` returns null for an English phrase, surface the failure — do not invent syntax.
- **Every mutation is preceded by a backup.** `applyMutation` in `commands.zig` is the single funnel; new commands that change the crontab must route through it.
- **Managed jobs are identified solely by the `#looper#` marker line.** Lines without that marker are "foreign" and must be preserved untouched on serialize. `import` is the only path that adopts them.
- **Idempotency by `id`.** `add` with an existing id updates in place; never appends a duplicate.
- **No "remove all" command exists, by design.** `crontab -r` is the footgun this tool exists to avoid.
- **Disabled jobs keep their definition.** `disable` comments the payload line but leaves the marker (`enabled=0`); do not delete on disable.
- **Color is opt-in to a tty and `NO_COLOR`.** Use `ctx.k(CODE)` rather than hardcoding escape sequences so `--no-color` / `NO_COLOR` keep working.
- **Output goes through `ctx.emit` + `ctx.flush`,** not direct stdio. Errors go through `posix.eprint`. `ctx_mod.g_exit` / `g_fail()` accumulate non-fatal failures so a multi-target run still surfaces a non-zero exit.

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
```
