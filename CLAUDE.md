# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`looper` is a single-file Zig CLI that manages cron jobs — locally, for another user, on remote hosts over `ssh`, or in a plain crontab file. The entire program lives in `main.zig` (~1110 lines, Zig 0.16+, libc only). Prebuilt binaries for the supported targets sit alongside it.

## Build & run

```sh
# Native host build
zig build-exe main.zig -O ReleaseSafe -lc -femit-bin=looper

# Cross-compile for the fleet
zig build-exe main.zig -O ReleaseSafe -lc -target x86_64-linux-musl  -femit-bin=looper-x86_64-linux-musl
zig build-exe main.zig -O ReleaseSafe -lc -target aarch64-linux-musl -femit-bin=looper-aarch64-linux-musl
zig build-exe main.zig -O ReleaseSafe -lc -target aarch64-macos      -femit-bin=looper-aarch64-macos

# Quick syntax/type check without producing a binary
zig build-exe main.zig -lc -fno-emit-bin
```

There is no `build.zig`, no `zig build` target, and no package manager — invoke `zig` directly.

## Tests

The README claims `cronlogic.zig` is unit-tested via `zig test cronlogic.zig -lc`, but **that file is not present in the working tree** and `main.zig` contains no `test` blocks. Before quoting that command back to the user, check whether the file actually exists. If asked to add tests, either extract the cron engine into `cronlogic.zig` (the `Schedule`, `parseSchedule`, `nextRun`, `humanize`, `nlpToCron`, `toCron` block in `main.zig:97-465`) and add `test "..." { ... }` blocks there, or add tests inline at the bottom of `main.zig`.

## Source layout inside `main.zig`

Everything is in one file but it is organized in clear bands — when adding code, place it in the matching band rather than at the bottom:

| Band | Lines (approx) | Responsibility |
|---|---|---|
| C interop + process exec | 1–95 | `@cImport` of POSIX headers, `runCapture` / `runInherit` over `fork`/`execvp`/`waitpid`. Stdlib `std.process.Child` is deliberately avoided — the comment "sidesteps churning std.Io" is load-bearing. |
| Cron engine | 97–197 | `Schedule` bitsets, `parseSchedule`, DST-correct `nextRun` via libc `localtime_r`/`mktime`. Implements Vixie's DOM/DOW OR-rule. |
| Humanization + NLP | 199–465 | `humanize` for cron→English, `nlpToCron` for English→cron, `toCron` is the umbrella entry point used by `add`/`explain`. |
| Crontab model | 467–583 | `MARKER = "#looper#"`, `Job`, `Item` (raw line or job), `parseCrontab`, `serialize`. The marker line precedes the payload line. |
| Target backends | 585–670 | `Target { local | remote | file }` + `readCrontab` / `writeCrontab`. Remote targets shell out to `ssh`; local uses `crontab -l` / `crontab -` ; file targets read/write directly. |
| Backups & state | 671–706 | Backups land in `${XDG_STATE_HOME:-~/.local/state}/looper/backups/<target-slug>/<UTC-stamp>.crontab`. Every mutation backs up first. |
| Command implementations | 800–961 | `cmdLs`, `cmdAdd`, `cmdToggle`, `cmdRm`, `cmdShow`, `cmdRun`, `cmdExplain`, `cmdBackup`, `cmdRestore`, `cmdImport`. |
| CLI dispatch | 1011–1110 | `Cmd` enum, arg parser, target list construction, per-target loop. |

## Architectural rules to preserve

- **Never emit non-standard cron.** Schedules are validated by `parseSchedule` before any write. If `nlpToCron` returns null for an English phrase, surface the failure — do not invent syntax.
- **Every mutation is preceded by a backup.** `applyMutation` (around `main.zig:782`) is the single funnel; new commands that change the crontab must route through it.
- **Managed jobs are identified solely by the `#looper#` marker line.** Lines without that marker are "foreign" and must be preserved untouched on serialize. `import` is the only path that adopts them.
- **Idempotency by `id`.** `add` with an existing id updates in place; never appends a duplicate.
- **No "remove all" command exists, by design** — do not add one. `crontab -r` is the footgun this tool exists to avoid.
- **Disabled jobs keep their definition.** `disable` comments the payload line but leaves the marker (`enabled=0`); do not delete on disable.
- **Color is opt-in to a tty and `NO_COLOR`.** Use `ctx.k(CODE)` rather than hardcoding escape sequences so `--no-color` / `NO_COLOR` keep working.
- **Output goes through `ctx.emit` + `ctx.flush`,** not direct stdio. Errors go through `eprint`. `g_exit`/`g_fail` accumulate non-fatal failures so a multi-target run still surfaces a non-zero exit.

## Targets & invocation model

A single command can run against multiple targets — `-H host` (repeatable), `--all` (reads `~/.config/looper/hosts` or `$XDG_CONFIG_HOME/looper/hosts`), `-u user`, or `-f path`. The main loop at `main.zig:1085-1107` iterates targets, prints a `=== label ===` header in multi-target mode, and continues past per-target read failures rather than aborting the batch.

## Zig 0.16 specifics worth knowing

- Entry point is `pub fn main(init: std.process.Init.Minimal) !void` — argv comes from `init.args.toSlice(a)`, not `std.process.argsAlloc`.
- `std.ArrayList(T)` is used in the unmanaged style: `.empty` init, `appendSlice(a, ...)` with an explicit allocator on every call.
- An arena allocator backs everything in `main`; individual functions take `std.mem.Allocator` and may leak into the arena freely.
- POSIX calls go through `c.fork` / `c.execvp` / `c.waitpid` rather than `std.process.Child`; keep new subprocess work in that style for consistency.

## Useful runtime entry points for manual verification

```sh
# Roundtrip without touching the system crontab
./looper -f /tmp/test.crontab add --id demo "every weekday at 8am" "echo hi"
./looper -f /tmp/test.crontab ls
./looper -f /tmp/test.crontab show demo
./looper -f /tmp/test.crontab --dry-run rm demo

# Pure parser exercise — writes nothing
./looper explain "*/15 9-17 * * mon-fri"
./looper explain "every 15 min from 9am to 5pm on weekdays"
```

## Repo state

Not a git repository at the time of writing. If asked to commit, initialize one first and confirm with the user before pushing anywhere.
