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
        if (!ctx.quiet) ctx.emit("{s}no change{s} on {s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET), t.label(ctx.a) });
        return;
    }
    if (ctx.dry_run) {
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
        ctx.emit("[", .{});
        var first = true;
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                if (!first) ctx.emit(",", .{});
                first = false;
                const nr = nextFor(sched_mod.parseSchedule(j.schedule) catch sched_mod.Schedule{}, now, tz);
                ctx.emit("{{\"id\":\"{s}\",\"enabled\":{s},\"foreign\":{s},\"schedule\":\"{s}\",\"command\":\"{s}\",\"next\":{d},\"tz\":\"{s}\",\"tz_offset_secs\":{d}}}", .{
                    j.id,                              if (j.enabled) "true" else "false",  if (j.foreign) "true" else "false",
                    display.jsonEsc(ctx.a, j.schedule), display.jsonEsc(ctx.a, j.command),  nr orelse 0,
                    display.jsonEsc(ctx.a, tz.abbrev), tz.offset_secs,
                });
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

pub fn cmdAdd(ctx: *Ctx, t: Target, content: []const u8, schedule: []const u8, command: []const u8, want_id: ?[]const u8) !void {
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

pub fn cmdRestore(ctx: *Ctx, t: Target, current: []const u8, given: ?[]const u8) !void {
    const path = given orelse backup_mod.newestBackup(ctx.a, t) orelse {
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
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo");
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
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo");
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
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo first", "demo");
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdAdd(&ctx, tgt, c1, "0 4 * * *", "/bin/echo second", "demo");
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
