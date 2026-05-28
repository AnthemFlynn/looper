//! `looper history <id>` / `looper last <id>` — the agent's read side
//! of the feedback loop. Both read execution records from
//! `$XDG_STATE_HOME/looper/runs/`, filtered to a single source_id, and
//! sorted newest-first. They never touch the crontab.
//!
//! `history` emits `{schema_version, runs: [...]}`; `last` emits a
//! single record object directly (with `schema_version`), matching the
//! "give me just the most recent run" intent.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const runs_mod = @import("../crontab/runs.zig");
const target_mod = @import("../crontab/target.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");
const humanize = @import("../cron/humanize.zig");

const Ctx = ctx_mod.Ctx;
const RunRecord = runs_mod.RunRecord;

const SCHEMA_VERSION: u32 = 1;

fn statusStr(s: runs_mod.RunStatus) []const u8 {
    return switch (s) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .failed => "failed",
    };
}

fn primaryTime(r: RunRecord) i64 {
    if (r.finished_at) |t| return t;
    if (r.started_at) |t| return t;
    if (r.scheduled_for) |t| return t;
    // Records with no timestamps tail-sort under "newest-first" — for
    // history (a query of *executed* runs only), this branch is
    // effectively unreachable since `_exec`'s first write sets
    // `started_at` before anything else. The runs.zig copy of this
    // helper deliberately returns maxInt because that surface
    // synthesizes pending records and wants them at the top.
    return 0;
}

fn lessNewerFirst(_: void, a: RunRecord, b: RunRecord) bool {
    return primaryTime(a) > primaryTime(b);
}

/// Return all run records whose `source_id` matches `id`, sorted
/// newest-first. The slice is freshly allocated under `a` — callers
/// using an arena get the usual lifetime.
fn runsForId(a: std.mem.Allocator, id: []const u8) ![]RunRecord {
    const all = try runs_mod.listRuns(a);
    var out: std.ArrayList(RunRecord) = .empty;
    for (all) |r| {
        const sid = r.source_id orelse continue;
        if (!std.mem.eql(u8, sid, id)) continue;
        try out.append(a, r);
    }
    const slice = try out.toOwnedSlice(a);
    std.mem.sort(RunRecord, slice, {}, lessNewerFirst);
    return slice;
}

fn emitRecordJson(ctx: *Ctx, r: RunRecord) void {
    const status = runs_mod.statusOf(r);
    ctx.emit("{{\"run_id\":\"{s}\",\"status\":\"{s}\"", .{
        display.jsonEsc(ctx.a, r.run_id), statusStr(status),
    });
    ctx.emit(",\"source_id\":", .{});
    if (r.source_id) |sid| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, sid)}) else ctx.emit("null", .{});
    ctx.emit(",\"command\":\"{s}\"", .{display.jsonEsc(ctx.a, r.command)});
    ctx.emit(",\"target_label\":", .{});
    if (r.target_label) |tl| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, tl)}) else ctx.emit("null", .{});
    ctx.emit(",\"once\":{s}", .{if (r.once) "true" else "false"});
    if (r.scheduled_for) |t| ctx.emit(",\"scheduled_for\":{d}", .{t}) else ctx.emit(",\"scheduled_for\":null", .{});
    if (r.started_at) |t| ctx.emit(",\"started_at\":{d}", .{t}) else ctx.emit(",\"started_at\":null", .{});
    if (r.finished_at) |t| ctx.emit(",\"finished_at\":{d}", .{t}) else ctx.emit(",\"finished_at\":null", .{});
    if (r.exit_code) |code| ctx.emit(",\"exit_code\":{d}", .{code}) else ctx.emit(",\"exit_code\":null", .{});
    ctx.emit(",\"timed_out\":{s}", .{if (r.timed_out) "true" else "false"});
    if (r.created_by) |cb| ctx.emit(",\"created_by\":\"{s}\"", .{display.jsonEsc(ctx.a, cb)}) else ctx.emit(",\"created_by\":null", .{});
    ctx.emit("}}", .{});
}

pub fn cmdHistory(ctx: *Ctx, id: []const u8) !void {
    const list = try runsForId(ctx.a, id);
    if (ctx.json) {
        ctx.emit("{{\"schema_version\":{d},\"id\":\"{s}\",\"runs\":[", .{
            SCHEMA_VERSION, display.jsonEsc(ctx.a, id),
        });
        for (list, 0..) |r, i| {
            if (i > 0) ctx.emit(",", .{});
            emitRecordJson(ctx, r);
        }
        ctx.emit("]}}\n", .{});
        return;
    }
    if (list.len == 0) {
        ctx.emit("{s}no runs recorded for '{s}'{s}\n", .{ ctx.k(colors.DIM), id, ctx.k(colors.RESET) });
        return;
    }
    const now = posix.nowEpoch();
    ctx.emit("{s}{s} ({d} run(s)){s}\n", .{
        ctx.k(colors.BOLD), id, list.len, ctx.k(colors.RESET),
    });
    for (list) |r| {
        const status = runs_mod.statusOf(r);
        const status_color = switch (status) {
            .pending => ctx.k(colors.DIM),
            .running => ctx.k(colors.YELLOW),
            .done => ctx.k(colors.GREEN),
            .failed => ctx.k(colors.RED),
        };
        const ts_opt: ?i64 = r.finished_at orelse r.started_at orelse r.scheduled_for;
        const when = if (ts_opt) |ts| humanize.relTime(ctx.a, ts - now) else "—";
        ctx.emit("  {s}{s}{s}  {s}{s}{s}  exit={s}  {s}{s}{s}\n", .{
            ctx.k(colors.CYAN),  r.run_id,                                 ctx.k(colors.RESET),
            status_color,        statusStr(status),                        ctx.k(colors.RESET),
            if (r.exit_code) |code| std.fmt.allocPrint(ctx.a, "{d}", .{code}) catch "?" else "—",
            ctx.k(colors.DIM),  when, ctx.k(colors.RESET),
        });
    }
}

pub fn cmdLast(ctx: *Ctx, id: []const u8) !void {
    const list = try runsForId(ctx.a, id);
    if (list.len == 0) {
        if (ctx.json) {
            ctx.emit("{{\"schema_version\":{d},\"id\":\"{s}\",\"run\":null}}\n", .{
                SCHEMA_VERSION, display.jsonEsc(ctx.a, id),
            });
        } else {
            ctx.emit("{s}no runs recorded for '{s}'{s}\n", .{ ctx.k(colors.DIM), id, ctx.k(colors.RESET) });
        }
        ctx.fail(1);
        return;
    }
    const r = list[0];
    if (ctx.json) {
        // Emit the most-recent record at the top level (with
        // schema_version + id alongside). Agents that care about the
        // raw exit_code can read `.exit_code` directly.
        const status = runs_mod.statusOf(r);
        ctx.emit("{{\"schema_version\":{d},\"id\":\"{s}\",\"run_id\":\"{s}\",\"status\":\"{s}\"", .{
            SCHEMA_VERSION, display.jsonEsc(ctx.a, id),
            display.jsonEsc(ctx.a, r.run_id), statusStr(status),
        });
        ctx.emit(",\"source_id\":", .{});
        if (r.source_id) |sid| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, sid)}) else ctx.emit("null", .{});
        ctx.emit(",\"command\":\"{s}\"", .{display.jsonEsc(ctx.a, r.command)});
        ctx.emit(",\"target_label\":", .{});
        if (r.target_label) |tl| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, tl)}) else ctx.emit("null", .{});
        ctx.emit(",\"once\":{s}", .{if (r.once) "true" else "false"});
        if (r.scheduled_for) |t| ctx.emit(",\"scheduled_for\":{d}", .{t}) else ctx.emit(",\"scheduled_for\":null", .{});
        if (r.started_at) |t| ctx.emit(",\"started_at\":{d}", .{t}) else ctx.emit(",\"started_at\":null", .{});
        if (r.finished_at) |t| ctx.emit(",\"finished_at\":{d}", .{t}) else ctx.emit(",\"finished_at\":null", .{});
        if (r.exit_code) |code| ctx.emit(",\"exit_code\":{d}", .{code}) else ctx.emit(",\"exit_code\":null", .{});
        ctx.emit(",\"timed_out\":{s}", .{if (r.timed_out) "true" else "false"});
        if (r.created_by) |cb| ctx.emit(",\"created_by\":\"{s}\"", .{display.jsonEsc(ctx.a, cb)}) else ctx.emit(",\"created_by\":null", .{});
        ctx.emit("}}\n", .{});
        return;
    }
    const status = runs_mod.statusOf(r);
    const status_color = switch (status) {
        .pending => ctx.k(colors.DIM),
        .running => ctx.k(colors.YELLOW),
        .done => ctx.k(colors.GREEN),
        .failed => ctx.k(colors.RED),
    };
    ctx.emit("{s}{s}{s}  {s}{s}{s}\n", .{
        ctx.k(colors.BOLD), r.run_id, ctx.k(colors.RESET),
        status_color, statusStr(status), ctx.k(colors.RESET),
    });
    if (r.exit_code) |code| ctx.emit("  exit     : {d}\n", .{code});
    if (r.finished_at) |t| ctx.emit("  finished : {s}\n", .{humanize.fmtWhen(ctx.a, t)});
    if (r.started_at) |t| ctx.emit("  started  : {s}\n", .{humanize.fmtWhen(ctx.a, t)});
}

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true, .quiet = true };
}

fn writeRec(a: std.mem.Allocator, run_id: []const u8, source_id: []const u8, ts: i64, exit: i32) !void {
    try runs_mod.metaWrite(a, .{
        .run_id = run_id,
        .source_id = source_id,
        .command = "/bin/true",
        .scheduled_for = ts,
        .started_at = ts,
        .finished_at = ts,
        .exit_code = exit,
    });
}

fn cleanupRec(a: std.mem.Allocator, run_id: []const u8) void {
    const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch return;
    const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch return;
    _ = posix.c.unlink(meta_z.ptr);
    _ = posix.c.rmdir(dir_z.ptr);
}

test "cmdHistory --json with no matching records emits empty runs[]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    // Random id that no record could match — exercises the empty path
    // without depending on the runs dir state from other tests.
    const id = try std.fmt.allocPrint(a, "no-such-job-{x}", .{posix.nowEpoch()});
    try cmdHistory(&ctx, id);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"runs\":[]") != null);
}

test "cmdHistory filters by source_id (excludes other jobs' runs)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamp = posix.nowEpoch();
    const want_id = try std.fmt.allocPrint(a, "hist-want-{x}", .{stamp});
    const other_id = try std.fmt.allocPrint(a, "hist-other-{x}", .{stamp});
    const run_match = try std.fmt.allocPrint(a, "hist-rm-{x}", .{stamp});
    const run_skip = try std.fmt.allocPrint(a, "hist-rs-{x}", .{stamp});
    try writeRec(a, run_match, want_id, stamp, 0);
    try writeRec(a, run_skip, other_id, stamp, 0);
    defer cleanupRec(a, run_match);
    defer cleanupRec(a, run_skip);
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdHistory(&ctx, want_id);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, run_match) != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, run_skip) == null);
}

test "cmdLast returns the most recent matching run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamp = posix.nowEpoch();
    const sid = try std.fmt.allocPrint(a, "last-{x}", .{stamp});
    const older = try std.fmt.allocPrint(a, "last-old-{x}", .{stamp});
    const newer = try std.fmt.allocPrint(a, "last-new-{x}", .{stamp});
    try writeRec(a, older, sid, stamp - 100, 0);
    try writeRec(a, newer, sid, stamp, 0);
    defer cleanupRec(a, older);
    defer cleanupRec(a, newer);
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdLast(&ctx, sid);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, newer) != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, older) == null);
}

test "cmdLast on no records exits 1 and emits run:null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const id = try std.fmt.allocPrint(a, "no-runs-here-{x}", .{posix.nowEpoch()});
    try cmdLast(&ctx, id);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"run\":null") != null);
}

test "primaryTime returns 0 (tail-sort) for fully-null records" {
    // History never synthesizes pending records, so null-timestamp
    // records are a degraded-state-only branch. They should tail-sort
    // under "newest-first" so real runs come first.
    const r: RunRecord = .{ .run_id = "x", .command = "/bin/true" };
    try testing.expectEqual(@as(i64, 0), primaryTime(r));
}
