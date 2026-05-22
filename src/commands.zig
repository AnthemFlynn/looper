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

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

pub fn applyMutation(ctx: *Ctx, t: Target, content: []const u8, new_content: []const u8, verb: []const u8) !void {
    if (std.mem.eql(u8, content, new_content)) {
        if (!ctx.quiet) ctx.emit("{s}no change{s} on {s}\n", .{ ctx.k(ctx_mod.DIM), ctx.k(ctx_mod.RESET), t.label(ctx.a) });
        return;
    }
    if (ctx.dry_run) {
        ctx.emit("{s}# dry-run: {s} on {s} (nothing written){s}\n", .{ ctx.k(ctx_mod.YELLOW), verb, t.label(ctx.a), ctx.k(ctx_mod.RESET) });
        diff.printDiff(ctx, content, new_content);
        return;
    }
    const bpath = backup_mod.doBackup(ctx.a, t, content);
    target_mod.writeCrontab(ctx.a, t, new_content) catch |e| {
        posix.eprint("looper: write failed on {s}: {s}\n", .{ t.label(ctx.a), @errorName(e) });
        ctx_mod.g_fail();
        return;
    };
    if (!ctx.quiet) {
        ctx.emit("{s}\xe2\x9c\x93{s} {s} on {s}", .{ ctx.k(ctx_mod.GREEN), ctx.k(ctx_mod.RESET), verb, t.label(ctx.a) });
        if (bpath) |bp| ctx.emit("{s}  (backup: {s}){s}", .{ ctx.k(ctx_mod.DIM), bp, ctx.k(ctx_mod.RESET) });
        ctx.emit("\n", .{});
    }
}

pub fn cmdLs(ctx: *Ctx, t: Target, content: []const u8) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const now = posix.nowEpoch();
    if (ctx.json) {
        ctx.emit("[", .{});
        var first = true;
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                if (!first) ctx.emit(",", .{});
                first = false;
                const nr = next_run.nextRun(sched_mod.parseSchedule(j.schedule) catch sched_mod.Schedule{}, now);
                ctx.emit("{{\"id\":\"{s}\",\"enabled\":{s},\"foreign\":{s},\"schedule\":\"{s}\",\"command\":\"{s}\",\"next\":{d}}}", .{
                    j.id, if (j.enabled) "true" else "false", if (j.foreign) "true" else "false", display.jsonEsc(ctx.a, j.schedule), display.jsonEsc(ctx.a, j.command), nr orelse 0,
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
        ctx.emit("{s}no cron jobs on {s}{s}\n", .{ ctx.k(ctx_mod.DIM), t.label(ctx.a), ctx.k(ctx_mod.RESET) });
        return;
    }
    const w = display.termWidth();
    const cmd_w = if (w > 60) w - 56 else 24;
    ctx.emit("{s}{s}{s}{s}   {s}{s}\n", .{ ctx.k(ctx_mod.BOLD), display.padTo(ctx.a, "ID", 14), display.padTo(ctx.a, "SCHEDULE", 22), display.padTo(ctx.a, "NEXT RUN", 24), "COMMAND", ctx.k(ctx_mod.RESET) });
    var fcount: usize = 0;
    for (ct.items.items) |it| switch (it) {
        .job => |j| {
            const sched = sched_mod.parseSchedule(j.schedule) catch null;
            const nr: []const u8 = if (sched) |s| (if (next_run.nextRun(s, now)) |xx| humanize.fmtWhen(ctx.a, xx) else (if (s.reboot) "at boot" else "—")) else "INVALID";
            const idcol = if (j.foreign) blk: {
                fcount += 1;
                break :blk std.fmt.allocPrint(ctx.a, "f{d}", .{fcount}) catch "f?";
            } else j.id;
            const idcolor = if (j.foreign) ctx.k(ctx_mod.YELLOW) else ctx.k(ctx_mod.CYAN);
            const dotcolor = if (j.foreign) ctx.k(ctx_mod.YELLOW) else if (j.enabled) ctx.k(ctx_mod.GREEN) else ctx.k(ctx_mod.DIM);
            const dot = if (j.foreign) "?" else if (j.enabled) "\xe2\x97\x8f" else "\xe2\x97\x8b";
            ctx.emit("{s}{s}{s}{s}{s}{s}{s} {s}{s}{s} {s}\n", .{
                idcolor, display.padTo(ctx.a, idcol, 14), ctx.k(ctx_mod.RESET),
                ctx.k(ctx_mod.DIM), display.padTo(ctx.a, j.schedule, 22), ctx.k(ctx_mod.RESET),
                display.padTo(ctx.a, nr, 24),
                dotcolor, dot, ctx.k(ctx_mod.RESET),
                display.truncEllipsis(ctx.a, j.command, cmd_w),
            });
        },
        else => {},
    };
    if (foreign > 0) ctx.emit("{s}\n{d} unmanaged job(s) shown as f1..f{d} — remove with 'looper rm f1', or adopt with 'looper import'{s}\n", .{ ctx.k(ctx_mod.DIM), foreign, foreign, ctx.k(ctx_mod.RESET) });
}

pub fn cmdAdd(ctx: *Ctx, t: Target, content: []const u8, schedule: []const u8, command: []const u8, want_id: ?[]const u8) !void {
    const cron = nlp.toCron(ctx.a, schedule) orelse {
        posix.eprint("looper: couldn't read schedule '{s}'\n", .{schedule});
        posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        posix.eprint("  preview with: looper explain '{s}'\n", .{schedule});
        ctx_mod.g_fail();
        return;
    };
    _ = sched_mod.parseSchedule(cron) catch |e| {
        posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ cron, @errorName(e) });
        ctx_mod.g_fail();
        return;
    };
    if (!std.mem.eql(u8, cron, schedule))
        ctx.emit("{s}interpreted{s} \"{s}\" as {s}{s}{s}  ({s})\n", .{ ctx.k(ctx_mod.DIM), ctx.k(ctx_mod.RESET), schedule, ctx.k(ctx_mod.BOLD), cron, ctx.k(ctx_mod.RESET), humanize.humanize(ctx.a, cron) });
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
            ctx_mod.g_fail();
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
        ctx_mod.g_fail();
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

pub fn cmdShow(ctx: *Ctx, t: Target, content: []const u8, id: []const u8) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse {
        posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        ctx_mod.g_fail();
        return;
    };
    const j = ct.items.items[idx].job;
    ctx.emit("{s}{s}{s}{s}  {s}{s}{s}\n", .{ ctx.k(ctx_mod.BOLD), ctx.k(ctx_mod.CYAN), j.id, ctx.k(ctx_mod.RESET), if (j.enabled) ctx.k(ctx_mod.GREEN) else ctx.k(ctx_mod.DIM), if (j.enabled) "enabled" else "disabled", ctx.k(ctx_mod.RESET) });
    ctx.emit("  schedule : {s}{s}{s}\n", .{ ctx.k(ctx_mod.DIM), j.schedule, ctx.k(ctx_mod.RESET) });
    ctx.emit("  meaning  : {s}\n", .{humanize.humanize(ctx.a, j.schedule)});
    ctx.emit("  command  : {s}\n", .{j.command});
    ctx.emit("  target   : {s}\n", .{t.label(ctx.a)});
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
        const nr = next_run.nextRun(sched, from) orelse break;
        ctx.emit("    {s}\n", .{humanize.fmtWhen(ctx.a, nr)});
        from = nr;
    }
    if (t.kind == .remote) ctx.emit("  {s}(next-run times use this machine's timezone){s}\n", .{ ctx.k(ctx_mod.DIM), ctx.k(ctx_mod.RESET) });
}

pub fn cmdRun(ctx: *Ctx, t: Target, content: []const u8, id: []const u8) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse {
        posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        ctx_mod.g_fail();
        return;
    };
    const cmd = ct.items.items[idx].job.command;
    ctx.emit("{s}running '{s}' on {s}…{s}\n", .{ ctx.k(ctx_mod.DIM), id, t.label(ctx.a), ctx.k(ctx_mod.RESET) });
    ctx.flush();
    var argv: std.ArrayList([]const u8) = .empty;
    if (t.kind == .remote) {
        try argv.append(ctx.a, "ssh");
        try argv.append(ctx.a, t.host);
        try argv.append(ctx.a, cmd);
    } else {
        try argv.append(ctx.a, "/bin/sh");
        try argv.append(ctx.a, "-c");
        try argv.append(ctx.a, cmd);
    }
    const code = posix.runInherit(ctx.a, argv.items) catch 1;
    if (code != 0) ctx_mod.g_fail();
    ctx.emit("{s}exit {d}{s}\n", .{ if (code == 0) ctx.k(ctx_mod.GREEN) else ctx.k(ctx_mod.RED), code, ctx.k(ctx_mod.RESET) });
}

pub fn cmdExplain(ctx: *Ctx, input: []const u8) !void {
    const schedule = nlp.toCron(ctx.a, input) orelse {
        posix.eprint("looper: couldn't read schedule '{s}'\n", .{input});
        posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        ctx_mod.g_fail();
        return;
    };
    const sched = sched_mod.parseSchedule(schedule) catch |e| {
        posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ schedule, @errorName(e) });
        ctx_mod.g_fail();
        return;
    };
    if (!std.mem.eql(u8, schedule, input))
        ctx.emit("{s}\"{s}\"{s} \xe2\x86\x92 {s}{s}{s}\n", .{ ctx.k(ctx_mod.DIM), input, ctx.k(ctx_mod.RESET), ctx.k(ctx_mod.BOLD), schedule, ctx.k(ctx_mod.RESET) })
    else
        ctx.emit("{s}{s}{s}\n", .{ ctx.k(ctx_mod.BOLD), schedule, ctx.k(ctx_mod.RESET) });
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
        ctx_mod.g_fail();
        return;
    };
    ctx.emit("{s}\xe2\x9c\x93{s} backed up {s} to {s}\n", .{ ctx.k(ctx_mod.GREEN), ctx.k(ctx_mod.RESET), t.label(ctx.a), p });
}

pub fn cmdRestore(ctx: *Ctx, t: Target, current: []const u8, given: ?[]const u8) !void {
    const path = given orelse backup_mod.newestBackup(ctx.a, t) orelse {
        posix.eprint("looper: no backups for {s}\n", .{t.label(ctx.a)});
        ctx_mod.g_fail();
        return;
    };
    const data = target_mod.readFileAll(ctx.a, path) catch {
        posix.eprint("looper: cannot read backup {s}\n", .{path});
        ctx_mod.g_fail();
        return;
    };
    ctx.emit("{s}restoring {s} from {s}{s}\n", .{ ctx.k(ctx_mod.DIM), t.label(ctx.a), path, ctx.k(ctx_mod.RESET) });
    try applyMutation(ctx, t, current, data, "restored snapshot");
}

pub fn cmdImport(ctx: *Ctx, t: Target, content: []const u8) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var n: usize = 0;
    for (ct.items.items) |*it| switch (it.*) {
        .job => |*j| if (j.foreign) {
            j.foreign = false;
            j.enabled = true;
            j.id = display.slugUnique(ctx.a, &ct, j.command);
            n += 1;
        },
        else => {},
    };
    if (n == 0) {
        ctx.emit("{s}no unmanaged jobs to import on {s}{s}\n", .{ ctx.k(ctx_mod.DIM), t.label(ctx.a), ctx.k(ctx_mod.RESET) });
        return;
    }
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "imported {d} job(s)", .{n});
    try applyMutation(ctx, t, content, new_content, verb);
}
