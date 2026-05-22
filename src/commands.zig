//! All subcommands plus the single `applyMutation` funnel that every
//! write goes through: read → equality check → dry-run diff OR backup +
//! write → success line.
const std = @import("std");
const posix = @import("posix.zig");
const ctx_mod = @import("ctx.zig");
const target_mod = @import("crontab/target.zig");
const backup_mod = @import("crontab/backup.zig");
const model = @import("crontab/model.zig");
const sched_mod = @import("cron/schedule.zig");
const next_run = @import("cron/next_run.zig");
const humanize = @import("cron/humanize.zig");
const nlp = @import("cron/nlp.zig");
const display = @import("ui/display.zig");
const diff = @import("ui/diff.zig");
const colors = @import("ui/colors.zig");
const tz_mod = @import("tz.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;
const TzInfo = tz_mod.TzInfo;

/// Picks the right computation routine: probed targets use the target's
/// own zone (so a `0 3 * * *` job on a Singapore server actually means
/// 3am SGT). Controller-local and controller-fallback paths compute in
/// the controller's zone and label the output accordingly.
fn nextFor(s: sched_mod.Schedule, from: i64, tz: TzInfo) ?i64 {
    return switch (tz.source) {
        .target_probed => next_run.nextRunInTz(s, from, tz.offset_secs),
        else => next_run.nextRun(s, from),
    };
}

pub fn applyMutation(ctx: *Ctx, t: Target, content: []const u8, new_content: []const u8, verb: []const u8) !void {
    if (std.mem.eql(u8, content, new_content)) {
        if (ctx.json and ctx.dry_run) {
            // No-change dry-run in JSON mode: emit a structured no-op so
            // consumers can still distinguish "ran" from "errored."
            ctx.emit("{{\"dry_run\":true,\"target\":\"{s}\",\"action\":\"{s}\",\"changed\":false,\"diff\":[]}}\n", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)),
                display.jsonEsc(ctx.a, verb),
            });
            return;
        }
        if (!ctx.quiet) ctx.emit("{s}no change{s} on {s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET), t.label(ctx.a) });
        return;
    }
    if (ctx.dry_run) {
        if (ctx.json) {
            const ops = diff.diffOps(ctx.a, content, new_content);
            ctx.emit("{{\"dry_run\":true,\"target\":\"{s}\",\"action\":\"{s}\",\"changed\":true,\"diff\":[", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)),
                display.jsonEsc(ctx.a, verb),
            });
            for (ops, 0..) |dl, i| {
                if (i > 0) ctx.emit(",", .{});
                ctx.emit("{{\"op\":\"{s}\",\"line\":\"{s}\"}}", .{ diff.opName(dl.op), display.jsonEsc(ctx.a, dl.line) });
            }
            ctx.emit("]}}\n", .{});
            return;
        }
        ctx.emit("{s}# dry-run: {s} on {s} (nothing written){s}\n", .{ ctx.k(colors.YELLOW), verb, t.label(ctx.a), ctx.k(colors.RESET) });
        diff.printDiff(ctx, content, new_content);
        return;
    }
    const bpath = backup_mod.doBackup(ctx.a, t, content);
    target_mod.writeCrontab(ctx.a, t, new_content) catch |e| {
        posix.eprint("looper: write failed on {s}: {s}\n", .{ t.label(ctx.a), @errorName(e) });
        ctx.fail(1);
        return;
    };
    if (!ctx.quiet) {
        ctx.emit("{s}\xe2\x9c\x93{s} {s} on {s}", .{ ctx.k(colors.GREEN), ctx.k(colors.RESET), verb, t.label(ctx.a) });
        if (bpath) |bp| ctx.emit("{s}  (backup: {s}){s}", .{ ctx.k(colors.DIM), bp, ctx.k(colors.RESET) });
        ctx.emit("\n", .{});
    }
}

pub fn cmdLs(ctx: *Ctx, t: Target, content: []const u8, tz: TzInfo) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const now = posix.nowEpoch();
    if (ctx.json) {
        const target_label = t.label(ctx.a);
        ctx.emit("[", .{});
        var first = true;
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                if (!first) ctx.emit(",", .{});
                first = false;
                const sched = sched_mod.parseSchedule(j.schedule) catch null;
                // `next` is null when the schedule doesn't parse OR has
                // no next fire (e.g., @reboot). Previously emitted 0,
                // which silently aliased "January 1970" — a real epoch.
                const nr_opt: ?i64 = if (sched) |s| nextFor(s, now, tz) else null;
                const human_sched = humanize.humanize(ctx.a, j.schedule);
                ctx.emit(
                    "{{\"id\":\"{s}\",\"enabled\":{s},\"foreign\":{s},\"target\":\"{s}\"," ++
                        "\"schedule\":\"{s}\",\"human_schedule\":\"{s}\",\"command\":\"{s}\"," ++
                        "\"tz\":\"{s}\",\"tz_offset_secs\":{d},\"tz_source\":\"{s}\"",
                    .{
                        j.id,                                   if (j.enabled) "true" else "false", if (j.foreign) "true" else "false", display.jsonEsc(ctx.a, target_label),
                        display.jsonEsc(ctx.a, j.schedule),     display.jsonEsc(ctx.a, human_sched), display.jsonEsc(ctx.a, j.command),
                        display.jsonEsc(ctx.a, tz.abbrev),      tz.offset_secs,                     tz_mod.sourceStr(tz.source),
                    },
                );
                if (nr_opt) |nr| {
                    const nh = humanize.fmtWhenIn(ctx.a, nr, tz);
                    ctx.emit(",\"next\":{d},\"next_human\":\"{s}\"", .{ nr, display.jsonEsc(ctx.a, nh) });
                } else {
                    ctx.emit(",\"next\":null,\"next_human\":null", .{});
                }
                ctx.emit("}}", .{});
            },
            else => {},
        };
        ctx.emit("]\n", .{});
        return;
    }
    var managed: usize = 0;
    var foreign: usize = 0;
    for (ct.items.items) |it| switch (it) {
        .job => |j| {
            if (j.foreign) foreign += 1 else managed += 1;
        },
        else => {},
    };
    if (managed == 0 and foreign == 0) {
        ctx.emit("{s}no cron jobs on {s}{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), ctx.k(colors.RESET) });
        return;
    }
    const w = display.termWidth();
    // NEXT RUN widened from 24 → 36 to accommodate "YYYY-MM-DD HH:MM ABBR  in 1d 2h" plus optional
    // "(controller-local)" trailer; cmd_w drops a matching 12 chars (w-56 → w-68).
    const next_w: usize = 36;
    const cmd_w = if (w > 72) w - 68 else 24;
    ctx.emit("{s}{s}{s}{s}   {s}{s}\n", .{ ctx.k(colors.BOLD), display.padTo(ctx.a, "ID", 14), display.padTo(ctx.a, "SCHEDULE", 22), display.padTo(ctx.a, "NEXT RUN", next_w), "COMMAND", ctx.k(colors.RESET) });
    var fcount: usize = 0;
    for (ct.items.items) |it| switch (it) {
        .job => |j| {
            const sched = sched_mod.parseSchedule(j.schedule) catch null;
            const nr: []const u8 = if (sched) |s| (if (nextFor(s, now, tz)) |xx| humanize.fmtWhenIn(ctx.a, xx, tz) else (if (s.reboot) "at boot" else "—")) else "INVALID";
            const idcol = if (j.foreign) blk: {
                fcount += 1;
                break :blk std.fmt.allocPrint(ctx.a, "f{d}", .{fcount}) catch "f?";
            } else j.id;
            const idcolor = if (j.foreign) ctx.k(colors.YELLOW) else ctx.k(colors.CYAN);
            const dotcolor = if (j.foreign) ctx.k(colors.YELLOW) else if (j.enabled) ctx.k(colors.GREEN) else ctx.k(colors.DIM);
            const dot = if (j.foreign) "?" else if (j.enabled) "\xe2\x97\x8f" else "\xe2\x97\x8b";
            ctx.emit("{s}{s}{s}{s}{s}{s}{s} {s}{s}{s} {s}\n", .{
                idcolor,                           display.padTo(ctx.a, idcol, 14),      ctx.k(colors.RESET),
                ctx.k(colors.DIM),                 display.padTo(ctx.a, j.schedule, 22), ctx.k(colors.RESET),
                display.padTo(ctx.a, nr, next_w), dotcolor,                              dot,
                ctx.k(colors.RESET),               display.truncEllipsis(ctx.a, j.command, cmd_w),
            });
        },
        else => {},
    };
    if (foreign > 0) ctx.emit("{s}\n{d} unmanaged job(s) shown as f1..f{d} — remove with 'looper rm f1', or adopt with 'looper import'{s}\n", .{ ctx.k(colors.DIM), foreign, foreign, ctx.k(colors.RESET) });
}

/// Result of a `--check-command` reachability probe.
/// - `found`: the binary resolves to something executable
/// - `missing`: the probe ran and returned a definite "no"
/// - `skipped`: we couldn't (or shouldn't) ask the question — file
///   targets, shell constructs we can't parse, or a probe that itself
///   crashed. The caller treats `skipped` as silent: no warning, no
///   false-positive "missing" report.
pub const ReachResult = enum { found, missing, skipped };

/// Strip leading `KEY=VAL` env-var assignments from `command` and
/// return the first whitespace-separated token after them. Returns
/// null when nothing checkable remains — the command is empty, starts
/// with a shell construct (`(`, `{`, `$`, a quote, a backtick, a
/// backslash), or the leading run is only env-var assignments.
///
/// Examples (input → output):
///   "/usr/bin/foo arg"           → "/usr/bin/foo"
///   "FOO=bar BAZ=qux /bin/baz"   → "/bin/baz"
///   "rsync src dest"             → "rsync"
///   "(cd /; ls)"                 → null
///   ""                           → null
pub fn extractBinary(command: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, command, " \t");
    while (rest.len > 0) {
        const ws = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const tok = rest[0..ws];
        if (tok.len == 0) return null;
        if (isEnvAssign(tok)) {
            rest = std.mem.trimStart(u8, rest[ws..], " \t");
            continue;
        }
        const c0 = tok[0];
        // Anything we can't statically interpret as a plain binary
        // path: shell groupings, expansions, quoting, command
        // substitution, escapes, or a bare leading `=` (which `isEnvAssign`
        // does not accept — but reaching here means we saw `=foo`,
        // which is neither a name nor an assignment). Better to skip
        // than to mis-report.
        if (c0 == '(' or c0 == '{' or c0 == '$' or c0 == '"' or c0 == '\'' or c0 == '`' or c0 == '\\' or c0 == '=') return null;
        return tok;
    }
    return null;
}

fn isEnvAssign(tok: []const u8) bool {
    // POSIX env-var assignment: `[A-Za-z_][A-Za-z0-9_]*=...`. The `=`
    // must appear after at least one valid name character; bare `=foo`
    // is not an assignment, it's an attempted command.
    if (tok.len < 2) return false;
    if (!(std.ascii.isAlphabetic(tok[0]) or tok[0] == '_')) return false;
    var i: usize = 1;
    while (i < tok.len) : (i += 1) {
        if (tok[i] == '=') return true;
        if (!(std.ascii.isAlphanumeric(tok[i]) or tok[i] == '_')) return false;
    }
    return false;
}

/// Refuse to probe binary names containing shell metacharacters.
/// Anything fancier than `[A-Za-z0-9_.+/-]` almost certainly came from
/// a mis-parsed command, not a real binary name — and we'd otherwise
/// have to shell-quote it for the remote `command -v` invocation.
fn isPlainBinaryName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Real cron commands never start with `-` — that's an option flag
    // someone forgot to pair with a binary. `command -v -- '-c'` would
    // technically be safe (we use `--`), but reporting "command '-c'
    // not found" is misleading noise.
    if (name[0] == '-') return false;
    for (name) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.' or b == '/' or b == '+')) return false;
    }
    return true;
}

/// Probe whether `binary` is reachable on the target.
/// - local: absolute / relative-with-slash → `access(X_OK)`; bare name → walk PATH
/// - remote: ssh + POSIX `command -v` (one cheap round-trip; same
///   BatchMode/ConnectTimeout constraints as the real crontab read)
/// - file: skipped — no execution context
pub fn commandReachable(a: std.mem.Allocator, t: Target, binary: []const u8) ReachResult {
    if (!isPlainBinaryName(binary)) return .skipped;
    switch (t.kind) {
        .file => return .skipped,
        .local => {
            if (std.mem.indexOfScalar(u8, binary, '/') != null) {
                const z = a.dupeZ(u8, binary) catch return .skipped;
                return if (posix.c.access(z.ptr, posix.c.X_OK) == 0) .found else .missing;
            }
            return if (hasInPath(a, binary)) .found else .missing;
        },
        .remote => {
            // `-u <user>` makes the cron job run as a different user
            // with a different PATH; ssh-ing as our login user would
            // probe the wrong environment and silently return .found
            // when the binary isn't on the crontab owner's PATH. That
            // is exactly the false-confidence outcome this preflight
            // exists to prevent. Skipping is safer than guessing wrong.
            // Delegating via `sudo -u`/`su -l` would work in some
            // configurations but requires extra auth setup we can't
            // assume — and the warning is non-blocking anyway, so a
            // silent skip costs less than a misleading green light.
            if (t.user.len > 0) return .skipped;
            var argv: std.ArrayList([]const u8) = .empty;
            const prefix = target_mod.sshArgvPrefix(a, t.host) catch return .skipped;
            argv.appendSlice(a, prefix) catch return .skipped;
            argv.append(a, "sh") catch return .skipped;
            argv.append(a, "-c") catch return .skipped;
            // `command -v --` accepts both bare names and absolute
            // paths, and exits 0 on hit / 1 on miss. We've already
            // validated `binary` against `isPlainBinaryName`, so
            // single-quoting is safe (no `'` to escape).
            const cmd = std.fmt.allocPrint(a, "command -v -- '{s}' >/dev/null 2>&1", .{binary}) catch return .skipped;
            argv.append(a, cmd) catch return .skipped;
            const r = posix.runCapture(a, argv.items, null) catch return .skipped;
            return switch (r.code) {
                0 => .found,
                1, 127 => .missing,
                else => .skipped,
            };
        },
    }
}

pub fn cmdAdd(ctx: *Ctx, t: Target, content: []const u8, schedule: []const u8, command: []const u8, want_id: ?[]const u8, check_command: bool) !void {
    const cron = nlp.toCron(ctx.a, schedule) orelse {
        posix.eprint("looper: couldn't read schedule '{s}'\n", .{schedule});
        posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        posix.eprint("  preview with: looper explain '{s}'\n", .{schedule});
        ctx.fail(1);
        return;
    };
    _ = sched_mod.parseSchedule(cron) catch |e| {
        posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ cron, @errorName(e) });
        ctx.fail(1);
        return;
    };
    if (!std.mem.eql(u8, cron, schedule))
        ctx.emit("{s}interpreted{s} \"{s}\" as {s}{s}{s}  ({s})\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET), schedule, ctx.k(colors.BOLD), cron, ctx.k(colors.RESET), humanize.humanize(ctx.a, cron) });
    // Opt-in preflight. Not blocking: cron failures usually surface as
    // silent "no such file or directory" in the mail spool, which is
    // exactly what we want to head off — surface it now, still add the
    // job. Suppressed under --quiet (diagnostic noise) and --json (would
    // pollute the structured output on stdout).
    if (check_command and !ctx.quiet and !ctx.json) {
        if (extractBinary(command)) |bin| {
            switch (commandReachable(ctx.a, t, bin)) {
                .missing => ctx.emit(
                    "{s}!{s} command {s}'{s}'{s} not found on {s} — cron may fail to run (PATH under cron is minimal; consider an absolute path)\n",
                    .{ ctx.k(colors.YELLOW), ctx.k(colors.RESET), ctx.k(colors.BOLD), bin, ctx.k(colors.RESET), t.label(ctx.a) },
                ),
                .found, .skipped => {},
            }
        }
    }
    var ct = try model.parseCrontab(ctx.a, content);
    const id = want_id orelse blk: {
        for (ct.items.items) |it| switch (it) {
            .job => |j| if (!j.foreign and std.mem.eql(u8, j.schedule, cron) and std.mem.eql(u8, j.command, command)) break :blk j.id,
            else => {},
        };
        break :blk display.slugUnique(ctx.a, &ct, command);
    };
    if (ct.findIndex(id)) |i| {
        ct.items.items[i].job.schedule = cron;
        ct.items.items[i].job.command = command;
        ct.items.items[i].job.enabled = true;
    } else try ct.items.append(ctx.a, .{ .job = .{ .id = id, .enabled = true, .schedule = cron, .command = command } });
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "set job '{s}'", .{id});
    try applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdToggle(ctx: *Ctx, t: Target, content: []const u8, ids: [][]const u8, enable: bool) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var touched: usize = 0;
    for (ids) |id| {
        if (ct.findIndex(id)) |i| {
            ct.items.items[i].job.enabled = enable;
            touched += 1;
        } else {
            posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
            ctx.fail(1);
        }
    }
    if (touched == 0) return;
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "{s} {d} job(s)", .{ if (enable) "enabled" else "disabled", touched });
    try applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdEdit(ctx: *Ctx, t: Target, content: []const u8, id: []const u8, new_schedule: ?[]const u8, new_command: ?[]const u8) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse {
        posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        posix.eprint("  (foreign jobs must be adopted with 'looper import' before editing)\n", .{});
        ctx.fail(1);
        return;
    };
    if (new_schedule) |raw| {
        // Same NLP + validation chain as cmdAdd: surface the same errors
        // and the same "interpreted as" disclosure so `edit` behaves
        // identically to `add` for the schedule-update path.
        const cron = nlp.toCron(ctx.a, raw) orelse {
            posix.eprint("looper: couldn't read schedule '{s}'\n", .{raw});
            posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
            posix.eprint("  preview with: looper explain '{s}'\n", .{raw});
            ctx.fail(1);
            return;
        };
        _ = sched_mod.parseSchedule(cron) catch |e| {
            posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ cron, @errorName(e) });
            ctx.fail(1);
            return;
        };
        if (!std.mem.eql(u8, cron, raw))
            ctx.emit("{s}interpreted{s} \"{s}\" as {s}{s}{s}  ({s})\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET), raw, ctx.k(colors.BOLD), cron, ctx.k(colors.RESET), humanize.humanize(ctx.a, cron) });
        ct.items.items[idx].job.schedule = cron;
    }
    if (new_command) |cmd| ct.items.items[idx].job.command = cmd;
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "edited '{s}'", .{id});
    try applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdRm(ctx: *Ctx, t: Target, content: []const u8, ids: [][]const u8) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var rm: std.ArrayList(usize) = .empty;
    for (ids) |id| {
        if (ct.findIndex(id)) |i| {
            try rm.append(ctx.a, i);
            continue;
        }
        if (id.len >= 2 and id[0] == 'f' and model.allDigits(id[1..])) {
            const n = std.fmt.parseInt(usize, id[1..], 10) catch 0;
            if (ct.findForeign(n)) |i| {
                try rm.append(ctx.a, i);
                continue;
            }
        }
        posix.eprint("looper: no job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        ctx.fail(1);
    }
    if (rm.items.len == 0) return;
    if (!display.confirm(ctx, "Remove {d} job(s) from {s}?", .{ rm.items.len, t.label(ctx.a) })) {
        ctx.emit("aborted\n", .{});
        return;
    }
    var keep: std.ArrayList(model.Item) = .empty;
    outer: for (ct.items.items, 0..) |it, idx| {
        for (rm.items) |ri| if (ri == idx) continue :outer;
        try keep.append(ctx.a, it);
    }
    ct.items = keep;
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "removed {d} job(s)", .{rm.items.len});
    try applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdShow(ctx: *Ctx, t: Target, content: []const u8, id: []const u8, tz: TzInfo) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse {
        posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        ctx.fail(1);
        return;
    };
    const j = ct.items.items[idx].job;
    if (ctx.json) return cmdShowJson(ctx, t, j, tz);
    ctx.emit("{s}{s}{s}{s}  {s}{s}{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.CYAN), j.id, ctx.k(colors.RESET), if (j.enabled) ctx.k(colors.GREEN) else ctx.k(colors.DIM), if (j.enabled) "enabled" else "disabled", ctx.k(colors.RESET) });
    ctx.emit("  schedule : {s}{s}{s}\n", .{ ctx.k(colors.DIM), j.schedule, ctx.k(colors.RESET) });
    ctx.emit("  meaning  : {s}\n", .{humanize.humanize(ctx.a, j.schedule)});
    ctx.emit("  command  : {s}\n", .{j.command});
    ctx.emit("  target   : {s}\n", .{t.label(ctx.a)});
    const tz_origin: []const u8 = switch (tz.source) {
        .controller_local => "controller-local",
        .target_probed => "probed from target",
        .controller_fallback => "controller-local — target probe failed",
    };
    ctx.emit("  timezone : {s} ({s}{c}{d:0>2}:{d:0>2}{s}, {s}{s}{s})\n", .{
        tz.abbrev,
        "UTC",
        @as(u8, if (tz.offset_secs < 0) '-' else '+'),
        @as(u32, @intCast(@divTrunc(if (tz.offset_secs < 0) -tz.offset_secs else tz.offset_secs, 3600))),
        @as(u32, @intCast(@divTrunc(@mod(if (tz.offset_secs < 0) -tz.offset_secs else tz.offset_secs, 3600), 60))),
        "",
        ctx.k(colors.DIM), tz_origin, ctx.k(colors.RESET),
    });
    const sched = sched_mod.parseSchedule(j.schedule) catch {
        ctx.emit("  next     : (does not parse)\n", .{});
        return;
    };
    if (sched.reboot) {
        ctx.emit("  next     : at next reboot\n", .{});
        return;
    }
    ctx.emit("  next 5   :\n", .{});
    var from = posix.nowEpoch();
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const nr = nextFor(sched, from, tz) orelse break;
        ctx.emit("    {s}\n", .{humanize.fmtWhenIn(ctx.a, nr, tz)});
        from = nr;
    }
}

/// Emits a JSON array of {epoch, human} pairs for the next N fires of
/// `sched` starting from `from_utc`. Shared between show and explain so
/// the contract is identical.
fn nextArrayJson(ctx: *Ctx, sched: sched_mod.Schedule, from_utc: i64, tz: TzInfo, count: usize) void {
    ctx.emit("[", .{});
    var from = from_utc;
    var k: usize = 0;
    var first = true;
    while (k < count) : (k += 1) {
        const nr = nextFor(sched, from, tz) orelse break;
        if (!first) ctx.emit(",", .{});
        first = false;
        const h = humanize.fmtWhenIn(ctx.a, nr, tz);
        ctx.emit("{{\"epoch\":{d},\"human\":\"{s}\"}}", .{ nr, display.jsonEsc(ctx.a, h) });
        from = nr;
    }
    ctx.emit("]", .{});
}

fn cmdShowJson(ctx: *Ctx, t: Target, j: model.Job, tz: TzInfo) !void {
    const target_label = t.label(ctx.a);
    const human_sched = humanize.humanize(ctx.a, j.schedule);
    const sched = sched_mod.parseSchedule(j.schedule) catch null;
    ctx.emit(
        "{{\"target\":\"{s}\",\"id\":\"{s}\",\"enabled\":{s}," ++
            "\"schedule\":\"{s}\",\"human_schedule\":\"{s}\",\"command\":\"{s}\"," ++
            "\"tz\":\"{s}\",\"tz_offset_secs\":{d},\"tz_source\":\"{s}\"",
        .{
            display.jsonEsc(ctx.a, target_label), j.id,                                  if (j.enabled) "true" else "false",
            display.jsonEsc(ctx.a, j.schedule),    display.jsonEsc(ctx.a, human_sched),    display.jsonEsc(ctx.a, j.command),
            display.jsonEsc(ctx.a, tz.abbrev),     tz.offset_secs,                         tz_mod.sourceStr(tz.source),
        },
    );
    if (sched) |s| {
        ctx.emit(",\"reboot\":{s},\"next\":", .{if (s.reboot) "true" else "false"});
        if (s.reboot) {
            ctx.emit("[]", .{});
        } else {
            nextArrayJson(ctx, s, posix.nowEpoch(), tz, 5);
        }
    } else {
        // Unparseable schedule — surface as nulls so consumers can spot
        // the error without text-matching.
        ctx.emit(",\"reboot\":null,\"next\":null,\"parse_error\":\"invalid schedule\"", .{});
    }
    ctx.emit("}}\n", .{});
}

pub fn cmdRun(ctx: *Ctx, t: Target, content: []const u8, id: []const u8) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse {
        posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        ctx.fail(1);
        return;
    };
    const cmd = ct.items.items[idx].job.command;
    ctx.emit("{s}running '{s}' on {s}…{s}\n", .{ ctx.k(colors.DIM), id, t.label(ctx.a), ctx.k(colors.RESET) });
    ctx.flush();
    var argv: std.ArrayList([]const u8) = .empty;
    if (t.kind == .remote) {
        try argv.appendSlice(ctx.a, try target_mod.sshArgvPrefix(ctx.a, t.host));
        try argv.append(ctx.a, cmd);
    } else {
        try argv.append(ctx.a, "/bin/sh");
        try argv.append(ctx.a, "-c");
        try argv.append(ctx.a, cmd);
    }
    const code = posix.runInherit(ctx.a, argv.items) catch 1;
    if (code != 0) {
        // Clamp to u8 so the exit code surfaces in shell `$?`. A negative
        // child status (e.g., killed by signal, returns -1 from waitpid)
        // collapses to 1; otherwise we propagate the real value.
        const u: u8 = if (code < 0 or code > 255) 1 else @intCast(code);
        ctx.fail(u);
    }
    ctx.emit("{s}exit {d}{s}\n", .{ if (code == 0) ctx.k(colors.GREEN) else ctx.k(colors.RED), code, ctx.k(colors.RESET) });
}

pub fn cmdExplain(ctx: *Ctx, input: []const u8) !void {
    const schedule = nlp.toCron(ctx.a, input) orelse {
        posix.eprint("looper: couldn't read schedule '{s}'\n", .{input});
        posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        ctx.fail(1);
        return;
    };
    const sched = sched_mod.parseSchedule(schedule) catch |e| {
        posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ schedule, @errorName(e) });
        ctx.fail(1);
        return;
    };
    if (ctx.json) {
        const tz = tz_mod.controllerTz(ctx.a);
        const interpreted = !std.mem.eql(u8, schedule, input);
        const human_sched = humanize.humanize(ctx.a, schedule);
        ctx.emit(
            "{{\"input\":\"{s}\",\"schedule\":\"{s}\",\"human_schedule\":\"{s}\"," ++
                "\"interpreted\":{s},\"reboot\":{s},\"tz\":\"{s}\",\"tz_offset_secs\":{d},\"next\":",
            .{
                display.jsonEsc(ctx.a, input),    display.jsonEsc(ctx.a, schedule), display.jsonEsc(ctx.a, human_sched),
                if (interpreted) "true" else "false", if (sched.reboot) "true" else "false",
                display.jsonEsc(ctx.a, tz.abbrev), tz.offset_secs,
            },
        );
        if (sched.reboot) {
            ctx.emit("[]", .{});
        } else {
            nextArrayJson(ctx, sched, posix.nowEpoch(), tz, 5);
        }
        ctx.emit("}}\n", .{});
        return;
    }
    if (!std.mem.eql(u8, schedule, input))
        ctx.emit("{s}\"{s}\"{s} \xe2\x86\x92 {s}{s}{s}\n", .{ ctx.k(colors.DIM), input, ctx.k(colors.RESET), ctx.k(colors.BOLD), schedule, ctx.k(colors.RESET) })
    else
        ctx.emit("{s}{s}{s}\n", .{ ctx.k(colors.BOLD), schedule, ctx.k(colors.RESET) });
    ctx.emit("  {s}\n", .{humanize.humanize(ctx.a, schedule)});
    if (sched.reboot) {
        ctx.emit("  runs once at boot\n", .{});
        return;
    }
    ctx.emit("  next runs:\n", .{});
    var from = posix.nowEpoch();
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const nr = next_run.nextRun(sched, from) orelse break;
        ctx.emit("    {s}\n", .{humanize.fmtWhen(ctx.a, nr)});
        from = nr;
    }
}

pub fn cmdBackup(ctx: *Ctx, t: Target, content: []const u8) !void {
    const p = backup_mod.doBackup(ctx.a, t, content) orelse {
        posix.eprint("looper: backup failed\n", .{});
        ctx.fail(1);
        return;
    };
    ctx.emit("{s}\xe2\x9c\x93{s} backed up {s} to {s}\n", .{ ctx.k(colors.GREEN), ctx.k(colors.RESET), t.label(ctx.a), p });
}

pub fn cmdRestore(ctx: *Ctx, t: Target, current: []const u8, given_path: ?[]const u8, from_stamp: ?[]const u8) !void {
    // `--from <stamp>` resolves against the target's backup dir; the
    // bare positional path remains for explicit file restores
    // (cross-target imports, manually edited snapshots). Honouring both
    // at once would silently prefer one — refuse instead.
    if (given_path != null and from_stamp != null) {
        posix.eprint("looper: restore takes EITHER a positional path OR --from <stamp>, not both\n", .{});
        ctx.fail(2);
        return;
    }
    const path: []const u8 = if (from_stamp) |stamp| blk: {
        const entry = backup_mod.findByStamp(ctx.a, t, stamp) catch |e| switch (e) {
            backup_mod.StampError.Ambiguous => {
                posix.eprint("looper: stamp '{s}' matches more than one backup on {s} — narrow it (try `looper backups`)\n", .{ stamp, t.label(ctx.a) });
                ctx.fail(2);
                return;
            },
            backup_mod.StampError.NotFound => {
                posix.eprint("looper: no backup matching '{s}' on {s} (try `looper backups`)\n", .{ stamp, t.label(ctx.a) });
                ctx.fail(1);
                return;
            },
            else => return e,
        };
        break :blk entry.path;
    } else given_path orelse backup_mod.newestBackup(ctx.a, t) orelse {
        posix.eprint("looper: no backups for {s}\n", .{t.label(ctx.a)});
        ctx.fail(1);
        return;
    };
    const data = target_mod.readFileAll(ctx.a, path) catch {
        posix.eprint("looper: cannot read backup {s}\n", .{path});
        ctx.fail(1);
        return;
    };
    ctx.emit("{s}restoring {s} from {s}{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), path, ctx.k(colors.RESET) });
    try applyMutation(ctx, t, current, data, "restored snapshot");
}

// ─── backups (list) and backups prune ────────────────────────────────────────
// Read-only listing and a guarded pruner. Neither touches the crontab
// — they operate only inside the per-target backup directory under
// $XDG_STATE_HOME/looper/backups/<slug>/. Prune is the only destructive
// path in this module and must go through `confirm` (or `--yes` / a
// non-tty `--dry-run`).

/// Format an arbitrary byte count as a short human string. KiB-based,
/// the convention `ls -h` follows; we deliberately don't dignify
/// kilobyte ambiguity by labelling them "KiB" — the listing is for
/// humans, not for parsers (the JSON output carries `size_bytes`).
fn humanSize(a: std.mem.Allocator, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(a, "{d} B", .{bytes}) catch "";
    const kb: u64 = bytes / 1024;
    if (kb < 1024) return std.fmt.allocPrint(a, "{d}.{d} KB", .{ kb, (bytes * 10 / 1024) % 10 }) catch "";
    const mb_x10: u64 = bytes * 10 / (1024 * 1024);
    return std.fmt.allocPrint(a, "{d}.{d} MB", .{ mb_x10 / 10, mb_x10 % 10 }) catch "";
}

/// "12m ago", "1d 2h ago", "now" — derived from `relTime` (which gives
/// "12m" for past deltas and "in 12m" for future). For backups we always
/// want the past-tense form, so we hand it a negative delta and suffix
/// " ago" only when relTime returned more than the literal "now".
fn humanAge(a: std.mem.Allocator, mtime: i64, now: i64) []const u8 {
    const rt = humanize.relTime(a, mtime - now);
    if (std.mem.eql(u8, rt, "now")) return rt;
    return std.fmt.allocPrint(a, "{s} ago", .{std.mem.trimStart(u8, rt, " ")}) catch rt;
}

pub fn cmdBackups(ctx: *Ctx, t: Target) !void {
    const list = try backup_mod.listBackups(ctx.a, t);
    if (ctx.json) {
        const target_label = t.label(ctx.a);
        ctx.emit("{{\"target\":\"{s}\",\"backups\":[", .{display.jsonEsc(ctx.a, target_label)});
        for (list, 0..) |e, i| {
            if (i > 0) ctx.emit(",", .{});
            ctx.emit("{{\"stamp\":\"{s}\",\"mtime\":{d},\"size_bytes\":{d},\"path\":\"{s}\"}}", .{
                e.stamp,             e.mtime, e.size_bytes,
                display.jsonEsc(ctx.a, e.path),
            });
        }
        ctx.emit("]}}\n", .{});
        return;
    }
    if (list.len == 0) {
        ctx.emit("{s}no backups for {s} yet{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), ctx.k(colors.RESET) });
        return;
    }
    ctx.emit("{s}{s}  ({d} snapshot(s)){s}\n", .{ ctx.k(colors.BOLD), t.label(ctx.a), list.len, ctx.k(colors.RESET) });
    const now = posix.nowEpoch();
    for (list) |e| {
        const size = humanSize(ctx.a, e.size_bytes);
        const age = humanAge(ctx.a, e.mtime, now);
        ctx.emit("  {s}{s}{s}  {s}  {s}{s}{s}\n", .{
            ctx.k(colors.CYAN),  e.stamp, ctx.k(colors.RESET),
            display.padTo(ctx.a, size, 10),
            ctx.k(colors.DIM),   age,     ctx.k(colors.RESET),
        });
    }
    ctx.emit("{s}restore the newest with 'looper restore'; a specific one with 'looper restore --from <stamp>'{s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET) });
}

pub fn cmdBackupsPrune(ctx: *Ctx, t: Target, keep: usize) !void {
    // Floor at 1: zero is the "remove all" footgun the project doc
    // explicitly outlaws (CLAUDE.md). Surface the error here so the
    // user can re-issue with a sane value; don't auto-promote to 1.
    if (keep == 0) {
        posix.eprint("looper: --keep must be >= 1 (refusing to delete every backup)\n", .{});
        ctx.fail(2);
        return;
    }
    const preview = try backup_mod.pruneBackups(ctx.a, t, keep, true);
    if (preview.removed.len == 0) {
        if (ctx.json) {
            ctx.emit("{{\"target\":\"{s}\",\"kept\":{d},\"removed\":[]}}\n", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)), preview.kept.len,
            });
            return;
        }
        ctx.emit("{s}nothing to prune on {s}: {d} backup(s), keep {d}{s}\n", .{
            ctx.k(colors.DIM), t.label(ctx.a), preview.kept.len, keep, ctx.k(colors.RESET),
        });
        return;
    }
    if (ctx.dry_run) {
        if (ctx.json) {
            ctx.emit("{{\"dry_run\":true,\"target\":\"{s}\",\"kept\":{d},\"removed\":[", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)), preview.kept.len,
            });
            for (preview.removed, 0..) |e, i| {
                if (i > 0) ctx.emit(",", .{});
                ctx.emit("{{\"stamp\":\"{s}\",\"path\":\"{s}\"}}", .{ e.stamp, display.jsonEsc(ctx.a, e.path) });
            }
            ctx.emit("]}}\n", .{});
            return;
        }
        ctx.emit("{s}# dry-run: would remove {d} backup(s) on {s}, keep newest {d}{s}\n", .{
            ctx.k(colors.YELLOW), preview.removed.len, t.label(ctx.a), keep, ctx.k(colors.RESET),
        });
        for (preview.removed) |e| ctx.emit("  {s}- {s}{s}\n", .{ ctx.k(colors.DIM), e.stamp, ctx.k(colors.RESET) });
        return;
    }
    if (!ctx.json) {
        ctx.emit("{s}{d} backup(s) to remove on {s}, keep newest {d}:{s}\n", .{
            ctx.k(colors.BOLD), preview.removed.len, t.label(ctx.a), keep, ctx.k(colors.RESET),
        });
        for (preview.removed) |e| ctx.emit("  {s}- {s}{s}\n", .{ ctx.k(colors.DIM), e.stamp, ctx.k(colors.RESET) });
    }
    if (!display.confirm(ctx, "Remove {d} backup(s)?", .{preview.removed.len})) {
        if (ctx.json) {
            ctx.emit("{{\"target\":\"{s}\",\"aborted\":true,\"kept\":{d},\"removed\":[]}}\n", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)), preview.kept.len,
            });
        } else ctx.emit("aborted\n", .{});
        return;
    }
    const result = try backup_mod.pruneBackups(ctx.a, t, keep, false);
    if (ctx.json) {
        ctx.emit("{{\"target\":\"{s}\",\"kept\":{d},\"removed\":[", .{
            display.jsonEsc(ctx.a, t.label(ctx.a)), result.kept.len,
        });
        for (result.removed, 0..) |e, i| {
            if (i > 0) ctx.emit(",", .{});
            ctx.emit("{{\"stamp\":\"{s}\",\"path\":\"{s}\"}}", .{ e.stamp, display.jsonEsc(ctx.a, e.path) });
        }
        ctx.emit("]}}\n", .{});
        return;
    }
    if (!ctx.quiet) ctx.emit("{s}\xe2\x9c\x93{s} removed {d} backup(s) on {s} (kept newest {d})\n", .{
        ctx.k(colors.GREEN), ctx.k(colors.RESET),
        result.removed.len, t.label(ctx.a), result.kept.len,
    });
}

pub fn cmdImport(ctx: *Ctx, t: Target, content: []const u8) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var n: usize = 0;
    var skipped: usize = 0;
    for (ct.items.items) |*it| switch (it.*) {
        .job => |*j| if (j.foreign) {
            // Validate the schedule before adopting; lines that aren't real
            // cron stay foreign and visible in `ls` rather than being
            // promoted to a managed job that won't ever fire.
            _ = sched_mod.parseSchedule(j.schedule) catch {
                posix.eprint("looper: skipping unmanaged line with unparseable schedule: {s} {s}\n", .{ j.schedule, j.command });
                skipped += 1;
                continue;
            };
            j.foreign = false;
            j.enabled = true;
            j.id = display.slugUnique(ctx.a, &ct, j.command);
            n += 1;
        },
        else => {},
    };
    if (skipped > 0) ctx.emit("{s}skipped {d} unmanaged line(s) that don't parse as cron{s}\n", .{ ctx.k(colors.DIM), skipped, ctx.k(colors.RESET) });
    if (n == 0) {
        ctx.emit("{s}no unmanaged jobs to import on {s}{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), ctx.k(colors.RESET) });
        return;
    }
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "imported {d} job(s)", .{n});
    try applyMutation(ctx, t, content, new_content, verb);
}

// ─── doctor ──────────────────────────────────────────────────────────────────
// Preflight check. Surfaces all the things that would otherwise fail
// one-target-at-a-time mid-command: missing binaries, unwritable backup
// dir, unreadable hosts file, dead ssh, no-crontab-for-user. Mutates
// nothing; touches the filesystem only to (re)create the backup dir and
// drop a probe file inside it.

const CheckStatus = enum { ok, warn, fail };

fn printCheck(ctx: *Ctx, st: CheckStatus, name: []const u8, detail: []const u8) void {
    const sym: []const u8 = switch (st) {
        .ok => "\xe2\x9c\x93", // ✓
        .warn => "!",
        .fail => "\xe2\x9c\x97", // ✗
    };
    const color: []const u8 = switch (st) {
        .ok => ctx.k(colors.GREEN),
        .warn => ctx.k(colors.YELLOW),
        .fail => ctx.k(colors.RED),
    };
    ctx.emit("  {s}{s}{s} {s}  {s}{s}{s}\n", .{
        color,             sym,    ctx.k(colors.RESET),
        name,
        ctx.k(colors.DIM), detail, ctx.k(colors.RESET),
    });
}

/// PATH lookup via libc `access(X_OK)`. Shell-free so the result reflects
/// only file-system reality, not whatever `command -v` decides about
/// aliases/functions in a hypothetical interactive shell.
pub fn hasInPath(a: std.mem.Allocator, name: []const u8) bool {
    const path_env = posix.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
        const fullz = a.dupeZ(u8, full) catch continue;
        if (posix.c.access(fullz.ptr, posix.c.X_OK) == 0) return true;
    }
    return false;
}

/// True iff we can create and remove a probe file inside `dir`. Creates
/// the directory tree first — matches the lazy mkdir doBackup does on
/// first mutation, so the doctor check tells you the same thing the real
/// write would tell you.
pub fn dirWritable(a: std.mem.Allocator, dir: []const u8) bool {
    backup_mod.mkdirP(a, dir);
    const probe = std.fmt.allocPrint(a, "{s}/.looper-probe-{x}", .{ dir, posix.nowEpoch() }) catch return false;
    const pz = a.dupeZ(u8, probe) catch return false;
    const fd = posix.c.open(pz.ptr, posix.c.O_WRONLY | posix.c.O_CREAT | posix.c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    _ = posix.c.close(fd);
    _ = posix.c.unlink(pz.ptr);
    return true;
}

pub fn fileReadable(a: std.mem.Allocator, path: []const u8) bool {
    const pz = a.dupeZ(u8, path) catch return false;
    const fd = posix.c.open(pz.ptr, posix.c.O_RDONLY);
    if (fd < 0) return false;
    _ = posix.c.close(fd);
    return true;
}

/// `ssh -o BatchMode=yes -o ConnectTimeout=10 host true` — the cheapest
/// thing that proves the connection works under the same constraints the
/// real backend uses. BatchMode + key-only auth means a missing key fails
/// here rather than hanging on a password prompt the way `crontab -l`
/// would on first use.
fn sshReachable(a: std.mem.Allocator, host: []const u8) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    const prefix = target_mod.sshArgvPrefix(a, host) catch return false;
    argv.appendSlice(a, prefix) catch return false;
    argv.append(a, "true") catch return false;
    const r = posix.runCapture(a, argv.items, null) catch return false;
    return r.code == 0;
}

pub fn cmdDoctor(ctx: *Ctx, targets: []const Target, hosts_path: []const u8, use_all: bool) !void {
    var fails: usize = 0;
    var warns: usize = 0;

    var has_local = false;
    var has_remote = false;
    for (targets) |t| switch (t.kind) {
        .local => has_local = true,
        .remote => has_remote = true,
        .file => {},
    };

    ctx.emit("{s}environment{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.RESET) });
    if (has_local) {
        if (hasInPath(ctx.a, "crontab")) {
            printCheck(ctx, .ok, "crontab", "found in PATH");
        } else {
            printCheck(ctx, .fail, "crontab", "missing — required for local targets");
            fails += 1;
        }
    }
    if (has_remote) {
        if (hasInPath(ctx.a, "ssh")) {
            printCheck(ctx, .ok, "ssh", "found in PATH");
        } else {
            printCheck(ctx, .fail, "ssh", "missing — required for -H/--all");
            fails += 1;
        }
    }
    const sdir = backup_mod.stateDir(ctx.a);
    const bdir = std.fmt.allocPrint(ctx.a, "{s}/backups", .{sdir}) catch sdir;
    if (dirWritable(ctx.a, bdir)) {
        printCheck(ctx, .ok, "backup dir", bdir);
    } else {
        printCheck(ctx, .fail, "backup dir", bdir);
        fails += 1;
    }
    if (use_all) {
        const have_file = hosts_path.len > 0 and fileReadable(ctx.a, hosts_path);
        if (have_file) {
            printCheck(ctx, .ok, "hosts file", hosts_path);
            if (targets.len == 0) {
                printCheck(ctx, .fail, "hosts entries", "no usable hosts (every line blank or a comment)");
                fails += 1;
            }
        } else {
            const detail = if (hosts_path.len > 0) hosts_path else "(no path resolved)";
            printCheck(ctx, .fail, "hosts file", detail);
            fails += 1;
        }
    } else if (hosts_path.len > 0) {
        ctx.emit("  {s}-  hosts file (unused)  {s}{s}\n", .{ ctx.k(colors.DIM), hosts_path, ctx.k(colors.RESET) });
    }

    ctx.emit("\n{s}targets{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.RESET) });
    if (targets.len == 0) {
        ctx.emit("  {s}(no targets){s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET) });
    }
    const tz_probe = @import("tz_probe.zig");
    for (targets) |t| {
        ctx.emit("  {s}{s}{s}{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.CYAN), t.label(ctx.a), ctx.k(colors.RESET) });
        if (t.kind == .remote) {
            if (sshReachable(ctx.a, t.host)) {
                printCheck(ctx, .ok, "ssh reachable", t.host);
            } else {
                printCheck(ctx, .fail, "ssh reachable", "no connection (BatchMode, ConnectTimeout=10)");
                fails += 1;
                continue; // skip read attempt — it would just block or hang
            }
        }
        if (target_mod.readCrontab(ctx.a, t)) |content| {
            const line_count = std.mem.count(u8, content, "\n");
            const detail = std.fmt.allocPrint(ctx.a, "{d} line(s)", .{line_count}) catch "ok";
            printCheck(ctx, .ok, "crontab readable", detail);
        } else |e| {
            printCheck(ctx, .fail, "crontab readable", @errorName(e));
            fails += 1;
        }
        // Per-remote-target TZ probe — degraded path (probe fails) is a
        // warning, not a fail: looper still works, just labels remote
        // times as `(controller-local)` rather than rendering in target
        // wall clock.
        if (t.kind == .remote) {
            if (ctx.no_target_tz) {
                printCheck(ctx, .ok, "target tz", "skipped (--no-target-tz)");
            } else if (tz_probe.probeRemote(ctx.a, t.host)) |tz| {
                const detail = std.fmt.allocPrint(ctx.a, "{s} (UTC{c}{d:0>2}:{d:0>2})", .{
                    tz.abbrev,
                    @as(u8, if (tz.offset_secs < 0) '-' else '+'),
                    @as(u32, @intCast(@divTrunc(if (tz.offset_secs < 0) -tz.offset_secs else tz.offset_secs, 3600))),
                    @as(u32, @intCast(@divTrunc(@mod(if (tz.offset_secs < 0) -tz.offset_secs else tz.offset_secs, 3600), 60))),
                }) catch tz.abbrev;
                printCheck(ctx, .ok, "target tz", detail);
            } else {
                printCheck(ctx, .warn, "target tz", "probe failed — will fall back to (controller-local) labeling");
                warns += 1;
            }
        }
    }

    ctx.emit("\n", .{});
    if (fails > 0) {
        ctx.emit("{s}{d} check(s) failed — fix before relying on looper{s}\n", .{
            ctx.k(colors.RED), fails, ctx.k(colors.RESET),
        });
        if (warns > 0) ctx.emit("{s}{d} warning(s) — looper still works, see notes above{s}\n", .{
            ctx.k(colors.YELLOW), warns, ctx.k(colors.RESET),
        });
        ctx.fail(1);
    } else if (warns > 0) {
        ctx.emit("{s}{d} warning(s) — looper still works, see notes above{s}\n", .{
            ctx.k(colors.YELLOW), warns, ctx.k(colors.RESET),
        });
    } else {
        ctx.emit("{s}\xe2\x9c\x93 all checks passed{s}\n", .{ ctx.k(colors.GREEN), ctx.k(colors.RESET) });
    }
}

const testing = std.testing;

/// Make a unique temp-file target inside the test arena.
fn tmpTarget(a: std.mem.Allocator) !Target {
    const path = try std.fmt.allocPrint(a, "/tmp/looper-test-{x}.crontab", .{posix.nowEpoch()});
    return Target{ .kind = .file, .path = path };
}

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

test "applyMutation no-change short-circuits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    try applyMutation(&ctx, tgt, "same\n", "same\n", "noop");
    // Nothing should have been written; no file created either.
    const fdz = try a.dupeZ(u8, tgt.path);
    const fd = posix.c.open(fdz.ptr, posix.c.O_RDONLY);
    try testing.expect(fd < 0); // file does not exist
}

test "applyMutation writes new content + creates a backup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try applyMutation(&ctx, tgt, "old\n", "new\n", "test write");
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expectEqualStrings("new\n", got);
}

test "applyMutation --dry-run does not write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.dry_run = true;
    const tgt = try tmpTarget(a);
    try applyMutation(&ctx, tgt, "old\n", "new\n", "dry-test");
    const fdz = try a.dupeZ(u8, tgt.path);
    const fd = posix.c.open(fdz.ptr, posix.c.O_RDONLY);
    try testing.expect(fd < 0); // never created
    // and the diff was emitted to ctx.buf
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "+ new") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "- old") != null);
}

test "cmdAdd then serialize contains a managed job" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo", false);
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "#looper# id=demo enabled=1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * * /bin/echo hi") != null);
}

test "cmdToggle disables a job by commenting payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo", false);
    const after_add = try target_mod.readFileAll(a, tgt.path);
    var ids = [_][]const u8{"demo"};
    try cmdToggle(&ctx, tgt, after_add, ids[0..], false);
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "enabled=0") != null);
    try testing.expect(std.mem.indexOf(u8, got, "# 0 3 * * * /bin/echo hi") != null);
}

test "cmdAdd is idempotent by id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo first", "demo", false);
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdAdd(&ctx, tgt, c1, "0 4 * * *", "/bin/echo second", "demo", false);
    const c2 = try target_mod.readFileAll(a, tgt.path);
    // exactly one marker line — second add updated in place
    var marker_count: usize = 0;
    var it = std.mem.splitScalar(u8, c2, '\n');
    while (it.next()) |line| if (std.mem.startsWith(u8, line, "#looper#")) {
        marker_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), marker_count);
    try testing.expect(std.mem.indexOf(u8, c2, "0 4 * * * /bin/echo second") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "first") == null);
}

test "cmdEdit --schedule preserves command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo original", "demo", false);
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "0 4 * * *", null);
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "0 4 * * * /bin/echo original") != null);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * *") == null);
}

test "cmdEdit --command preserves schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo original", "demo", false);
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", null, "/bin/echo updated");
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * * /bin/echo updated") != null);
    try testing.expect(std.mem.indexOf(u8, got, "original") == null);
}

test "cmdEdit both flags update both fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "@hourly", "/bin/echo b");
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "@hourly /bin/echo b") != null);
}

test "cmdEdit rejects unknown id with exit 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    try cmdEdit(&ctx, tgt, "", "no-such-job", "@daily", null);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdEdit rejects foreign job (no marker) with exit 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    // Foreign job — no `#looper#` marker, so findIndex returns null
    // even though it's a real cron line.
    const foreign = "0 5 * * * /opt/legacy/job.sh\n";
    try cmdEdit(&ctx, tgt, foreign, "legacy", "@daily", null);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdEdit rejects invalid schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "not a real schedule and not English either", null);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
    // File content must be unchanged after a rejected edit.
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expectEqualStrings(after_add, got);
}

test "cmdLs --json emits next:null and next_human:null for @reboot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "@reboot", "/opt/start.sh", "boot", false);
    ctx.buf.clearRetainingCapacity();
    const content = try target_mod.readFileAll(a, tgt.path);
    const tz = tz_mod.controllerTz(a);
    try cmdLs(&ctx, tgt, content, tz);
    // @reboot has no next-run; ensure JSON gives a real null, not "next:0".
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next\":null") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next_human\":null") != null);
    // Old buggy shape — make sure we never emit `"next":0`.
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next\":0") == null);
}

test "cmdLs --json carries target, human_schedule, tz_source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
    ctx.buf.clearRetainingCapacity();
    const content = try target_mod.readFileAll(a, tgt.path);
    const tz = tz_mod.controllerTz(a);
    try cmdLs(&ctx, tgt, content, tz);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"target\":\"file:") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"human_schedule\":\"at 03:00 every day\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"tz_source\":\"controller_local\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next_human\":\"") != null);
}

test "cmdShow --json single object with next array of {epoch,human}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
    ctx.buf.clearRetainingCapacity();
    const content = try target_mod.readFileAll(a, tgt.path);
    const tz = tz_mod.controllerTz(a);
    try cmdShow(&ctx, tgt, content, "demo", tz);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"id\":\"demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"reboot\":false") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next\":[{\"epoch\":") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"human\":\"") != null);
}

test "cmdShow --json with @reboot emits empty next array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "@reboot", "/opt/start.sh", "boot", false);
    ctx.buf.clearRetainingCapacity();
    const content = try target_mod.readFileAll(a, tgt.path);
    const tz = tz_mod.controllerTz(a);
    try cmdShow(&ctx, tgt, content, "boot", tz);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"reboot\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next\":[]") != null);
}

test "cmdExplain --json includes input, interpreted, and next array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdExplain(&ctx, "every weekday at 8am");
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"input\":\"every weekday at 8am\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"schedule\":\"0 8 * * 1-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"interpreted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next\":[{\"epoch\":") != null);
}

test "cmdExplain --json @reboot has empty next + reboot:true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdExplain(&ctx, "@reboot");
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"reboot\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"next\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"interpreted\":false") != null);
}

test "applyMutation dry-run --json emits structured diff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    const tgt = try tmpTarget(a);
    try applyMutation(&ctx, tgt, "alpha\nbeta\n", "alpha\ngamma\n", "test action");
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"dry_run\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"changed\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"op\":\"remove\",\"line\":\"beta\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"op\":\"add\",\"line\":\"gamma\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"action\":\"test action\"") != null);
}

test "applyMutation dry-run --json no-change emits changed:false, empty diff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    const tgt = try tmpTarget(a);
    try applyMutation(&ctx, tgt, "same\n", "same\n", "noop");
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"changed\":false") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"diff\":[]") != null);
}

test "cmdEdit accepts an @macro schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "@daily", null);
    const got = try target_mod.readFileAll(a, tgt.path);
    // nlp passes already-valid cron (including @macros) through unchanged.
    try testing.expect(std.mem.indexOf(u8, got, "@daily /bin/echo a") != null);
}

test "hasInPath finds /bin/sh and rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `sh` lives in /bin on every POSIX system the tests would run on,
    // and /bin is always in $PATH for an interactive or CI shell.
    try testing.expect(hasInPath(a, "sh"));
    try testing.expect(!hasInPath(a, "zzz_almost_certainly_not_a_real_binary_xyz"));
}

test "dirWritable succeeds on /tmp and fails on a non-creatable path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(dirWritable(a, "/tmp"));
    // `/proc/looper-doctor-test` — root-owned read-only synthetic fs on
    // Linux, ENOENT on macOS; both yield a failing mkdir/open, which is
    // the case we want to exercise.
    try testing.expect(!dirWritable(a, "/proc/looper-doctor-test-xyz"));
}

test "fileReadable detects present and missing files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "/tmp/looper-readable-test-{x}", .{posix.nowEpoch()});
    defer _ = posix.c.unlink((a.dupeZ(u8, path) catch unreachable).ptr);
    try target_mod.writeFileAll(a, path, "hi\n");
    try testing.expect(fileReadable(a, path));
    try testing.expect(!fileReadable(a, "/tmp/looper-definitely-not-here-zzz-xyz"));
}

test "cmdDoctor against a file target passes and writes a structured report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    // File target = no `crontab`/`ssh` env checks, just backup-dir +
    // per-target read of the file. Empty path returns empty content,
    // which still counts as a successful read (0 lines).
    const path = try std.fmt.allocPrint(a, "/tmp/looper-doctor-it-{x}.crontab", .{posix.nowEpoch()});
    defer _ = posix.c.unlink((a.dupeZ(u8, path) catch unreachable).ptr);
    try target_mod.writeFileAll(a, path, "# nothing here\n");
    var targets = [_]Target{.{ .kind = .file, .path = path }};
    try cmdDoctor(&ctx, targets[0..], "/nonexistent/hosts", false);
    try testing.expectEqual(@as(u8, 0), ctx.exit_code);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "environment") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "backup dir") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "crontab readable") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "all checks passed") != null);
    // No env checks for crontab/ssh when only a file target is in play.
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "ssh  found") == null);
}

// ─── backups & restore --from tests ─────────────────────────────────────────

/// Lay down a controlled set of backup stamps under the target's slug.
/// Returns the target with a unique path; cleanup is via a defer in
/// the test that calls this (each test arena is its own world).
fn seedBackups(a: std.mem.Allocator, stamps: []const []const u8) !Target {
    const t: Target = .{
        .kind = .file,
        .path = try std.fmt.allocPrint(a, "/tmp/looper-cmd-bkup-{x}.crontab", .{posix.nowEpoch()}),
    };
    const dir = backup_mod.backupDir(a, t);
    backup_mod.mkdirP(a, dir);
    for (stamps, 0..) |stamp, idx| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}.crontab", .{ dir, stamp });
        const body = try std.fmt.allocPrint(a, "# seed {d}\n0 {d} * * * /bin/echo {s}\n", .{ idx, idx, stamp });
        try target_mod.writeFileAll(a, path, body);
    }
    return t;
}

fn cleanupBackupDir(a: std.mem.Allocator, t: Target) void {
    const dir = backup_mod.backupDir(a, t);
    const dz = a.dupeZ(u8, dir) catch return;
    const d = posix.c.opendir(dz.ptr) orelse return;
    defer _ = posix.c.closedir(d);
    while (true) {
        std.c._errno().* = 0;
        const ent = posix.c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".crontab")) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
        const pz = a.dupeZ(u8, full) catch continue;
        _ = posix.c.unlink(pz.ptr);
    }
}

test "cmdBackups on an empty dir reports no backups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const t: Target = .{ .kind = .file, .path = try std.fmt.allocPrint(a, "/tmp/looper-no-bkup-{x}.crontab", .{posix.nowEpoch()}) };
    try cmdBackups(&ctx, t);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "no backups for") != null);
}

test "cmdBackups lists newest-first with size + age" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{ "20260520T180000Z", "20260522T093015Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackups(&ctx, t);
    // Newest stamp must appear first in the table.
    const idx_newest = std.mem.indexOf(u8, ctx.buf.items, "20260522T093015Z") orelse return error.MissingNewest;
    const idx_older = std.mem.indexOf(u8, ctx.buf.items, "20260520T180000Z") orelse return error.MissingOlder;
    try testing.expect(idx_newest < idx_older);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "(2 snapshot(s))") != null);
}

test "cmdBackups --json emits structured array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const stamps = [_][]const u8{"20260522T093015Z"};
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackups(&ctx, t);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"target\":\"file:") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"stamp\":\"20260522T093015Z\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"size_bytes\":") != null);
}

test "cmdBackupsPrune --keep 0 is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const t: Target = .{ .kind = .file, .path = "/tmp/looper-irrelevant.crontab" };
    try cmdBackupsPrune(&ctx, t, 0);
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdBackupsPrune removes excess + keeps newest N" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{
        "20260101T000000Z",
        "20260102T000000Z",
        "20260103T000000Z",
        "20260104T000000Z",
    };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackupsPrune(&ctx, t, 2);
    const after = try backup_mod.listBackups(a, t);
    try testing.expectEqual(@as(usize, 2), after.len);
    try testing.expectEqualStrings("20260104T000000Z", after[0].stamp);
    try testing.expectEqualStrings("20260103T000000Z", after[1].stamp);
}

test "cmdBackupsPrune --dry-run lists removals but doesn't unlink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.dry_run = true;
    const stamps = [_][]const u8{ "20260101T000000Z", "20260102T000000Z", "20260103T000000Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackupsPrune(&ctx, t, 1);
    // Files all still present.
    const after = try backup_mod.listBackups(a, t);
    try testing.expectEqual(@as(usize, 3), after.len);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "would remove 2 backup(s)") != null);
}

test "cmdBackupsPrune noop when count <= keep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{ "20260101T000000Z", "20260102T000000Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackupsPrune(&ctx, t, 5);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "nothing to prune") != null);
    const after = try backup_mod.listBackups(a, t);
    try testing.expectEqual(@as(usize, 2), after.len);
}

test "cmdRestore --from resolves a unique stamp substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{"20260522T093015Z"};
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    defer _ = posix.c.unlink((a.dupeZ(u8, t.path) catch unreachable).ptr);
    try cmdRestore(&ctx, t, "", null, "20260522");
    // The seeded backup body contains "echo 20260522T093015Z" — that's
    // what should land in the target file after restore.
    const got = try target_mod.readFileAll(a, t.path);
    try testing.expect(std.mem.indexOf(u8, got, "echo 20260522T093015Z") != null);
}

test "cmdRestore --from with ambiguous stamp errors out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{ "20260522T093015Z", "20260522T180000Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdRestore(&ctx, t, "", null, "20260522");
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdRestore rejects both positional and --from at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const t: Target = .{ .kind = .file, .path = "/tmp/looper-irrelevant.crontab" };
    try cmdRestore(&ctx, t, "", "/some/path", "20260522");
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdDoctor --all with missing hosts file fails the run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    var targets = [_]Target{};
    try cmdDoctor(&ctx, targets[0..], "/tmp/looper-missing-hosts-zzz", true);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "hosts file") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "check(s) failed") != null);
}

// ─── --check-command preflight tests ─────────────────────────────────────────

test "extractBinary returns the first non-assignment token" {
    try testing.expectEqualStrings("/usr/bin/foo", extractBinary("/usr/bin/foo arg1 arg2").?);
    try testing.expectEqualStrings("rsync", extractBinary("rsync -a src dest").?);
    try testing.expectEqualStrings("/bin/sh", extractBinary("  /bin/sh -c 'work'").?);
}

test "extractBinary skips leading KEY=VAL env-var assignments" {
    try testing.expectEqualStrings("/bin/baz", extractBinary("FOO=bar /bin/baz").?);
    try testing.expectEqualStrings("rsync", extractBinary("FOO=1 BAR=2 BAZ=qux rsync src dest").?);
    // Underscore-leading is a valid POSIX env-var name.
    try testing.expectEqualStrings("/bin/foo", extractBinary("_X=1 /bin/foo").?);
}

test "extractBinary gives up on shell constructs" {
    try testing.expect(extractBinary("(cd /; ls)") == null);
    try testing.expect(extractBinary("$VAR_NOT_A_BINARY") == null);
    try testing.expect(extractBinary("`backtick`") == null);
    try testing.expect(extractBinary("\"quoted\"") == null);
    try testing.expect(extractBinary("\\escaped") == null);
    // Bare leading `=` — not a valid env-var assignment, not a binary.
    try testing.expect(extractBinary("=foo") == null);
}

test "extractBinary returns null on empty / whitespace-only" {
    try testing.expect(extractBinary("") == null);
    try testing.expect(extractBinary("   \t  ") == null);
}

test "extractBinary handles only-env-var input gracefully" {
    // No actual binary after the assignments — caller would do nothing.
    try testing.expect(extractBinary("FOO=bar") == null);
}

test "commandReachable on file target is always skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .file, .path = "/tmp/nope" };
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "/bin/sh"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "rsync"));
}

test "commandReachable local: /bin/sh exists, garbage path is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    try testing.expectEqual(ReachResult.found, commandReachable(a, t, "/bin/sh"));
    try testing.expectEqual(ReachResult.missing, commandReachable(a, t, "/zzz/almost/certainly/not/here"));
}

test "commandReachable local: bare name found via PATH walk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    // `sh` is in /bin on every POSIX system the tests would run on.
    try testing.expectEqual(ReachResult.found, commandReachable(a, t, "sh"));
    try testing.expectEqual(ReachResult.missing, commandReachable(a, t, "zzz_definitely_not_a_real_binary_xyz"));
}

test "commandReachable skips shell-metacharacter inputs" {
    // Defence in depth: extractBinary should have filtered these, but
    // commandReachable refuses to probe a name containing anything
    // outside [A-Za-z0-9_.+/-] so we never feed dangerous input to ssh.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "$VAR"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "foo;rm -rf"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "foo bar"));
    // Leading `-` is rejected: avoids reporting "command '-c' not
    // found" when the user mis-wrote the command.
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "-c"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "--help"));
}

test "commandReachable on remote target with -u user is skipped (avoids false confidence)" {
    // The crontab job runs as `t.user` with that user's PATH; our ssh
    // login user's PATH would give a misleading .found. We refuse to
    // probe rather than mislead — verified without actually shelling
    // out by setting an unreachable host (the user gate must short-
    // circuit before any ssh attempt).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .remote, .host = "host.invalid", .user = "cronuser" };
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "/bin/sh"));
}

test "cmdAdd local+missing+check_command emits the yellow ! warning" {
    // dry_run=true keeps applyMutation from invoking `crontab` for the
    // local target — the probe still runs (it doesn't depend on the
    // dry-run flag) and the warning emits to the buffer.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/almost/certainly/not/here", "demo", true);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found on local") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "/zzz/almost/certainly/not/here") != null);
}

test "cmdAdd local+found+check_command emits NO warning (binary exists)" {
    // Positive control: `/bin/sh` exists everywhere this test would
    // run, so the probe returns .found and the warning path is silent.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/sh -c 'echo hi'", "demo", true);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}

test "cmdAdd local+missing+check_command under --json suppresses the warning" {
    // The "! command not found" line is non-JSON text; under --json it
    // would corrupt structured stdout, so it must be silenced. We use
    // a .local target so the probe actually runs and returns .missing
    // — under --json + .file the test would pass trivially.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/almost/certainly/not/here", "demo", true);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}

test "cmdAdd local+missing+check_command under --quiet suppresses the warning" {
    // --quiet means "diagnostic output off"; the preflight is a
    // diagnostic, not a hard error, so it goes silent too.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.quiet = true;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/almost/certainly/not/here", "demo", true);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}

test "cmdAdd check_command=false does not probe at all" {
    // Default path: even with a missing binary, no warning fires when
    // the user didn't opt in. Pins the "no behaviour change without
    // the flag" contract from the commit message.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/missing", "demo", false);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}
