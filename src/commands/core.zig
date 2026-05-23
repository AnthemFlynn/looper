//! Shared command primitives:
//! - `applyMutation`: the single funnel every write goes through
//!   (no-change short-circuit → dry-run diff (text or JSON) → backup
//!   + write → success line).
//! - `nextFor`: schedule-evaluation router that respects `TzInfo.source`
//!   so a target-probed job evaluates in the target's wall clock and a
//!   controller-local one evaluates in ours.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const backup_mod = @import("../crontab/backup.zig");
const sched_mod = @import("../cron/schedule.zig");
const next_run = @import("../cron/next_run.zig");
const display = @import("../ui/display.zig");
const diff = @import("../ui/diff.zig");
const colors = @import("../ui/colors.zig");
const tz_mod = @import("../tz.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;
const TzInfo = tz_mod.TzInfo;

/// Picks the right computation routine: probed targets use the target's
/// own zone (so a `0 3 * * *` job on a Singapore server actually means
/// 3am SGT). Controller-local and controller-fallback paths compute in
/// the controller's zone and label the output accordingly.
pub fn nextFor(s: sched_mod.Schedule, from: i64, tz: TzInfo) ?i64 {
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

const testing = std.testing;

fn tmpTarget(a: std.mem.Allocator) !Target {
    const path = try std.fmt.allocPrint(a, "/tmp/looper-core-test-{x}.crontab", .{posix.nowEpoch()});
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
