//! Read-only commands: ls / show / run / explain. Nothing here writes
//! to the crontab; `cmdRun` does exec a subprocess, but that's the
//! user-requested side effect.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const sched_mod = @import("../cron/schedule.zig");
const next_run = @import("../cron/next_run.zig");
const humanize = @import("../cron/humanize.zig");
const nlp = @import("../cron/nlp.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");
const tz_mod = @import("../tz.zig");
const core = @import("core.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;
const TzInfo = tz_mod.TzInfo;

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
                const nr_opt: ?i64 = if (sched) |s| core.nextFor(s, now, tz) else null;
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
            const nr: []const u8 = if (sched) |s| (if (core.nextFor(s, now, tz)) |xx| humanize.fmtWhenIn(ctx.a, xx, tz) else (if (s.reboot) "at boot" else "—")) else "INVALID";
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
        const nr = core.nextFor(sched, from, tz) orelse break;
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
        const nr = core.nextFor(sched, from, tz) orelse break;
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

const testing = std.testing;
const mutate = @import("mutate.zig");

fn tmpTarget(a: std.mem.Allocator) !Target {
    const path = try std.fmt.allocPrint(a, "/tmp/looper-view-test-{x}.crontab", .{posix.nowEpoch()});
    return Target{ .kind = .file, .path = path };
}

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

test "cmdLs --json emits next:null and next_human:null for @reboot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try mutate.cmdAdd(&ctx, tgt, "", "@reboot", "/opt/start.sh", "boot", false);
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
    try mutate.cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
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
    try mutate.cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", false);
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
    try mutate.cmdAdd(&ctx, tgt, "", "@reboot", "/opt/start.sh", "boot", false);
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
