//! Unified-style diff for --dry-run. LCS-based; not optimized for huge
//! files but a crontab maxes out at hundreds of lines.
//!
//! Two-layer API: `diffOps` produces a structured `[]DiffLine` that
//! both `printDiff` (ANSI for terminals) and the JSON dry-run path
//! consume. The shared LCS pass means both renderers always agree.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const colors = @import("colors.zig");

pub const Op = enum { context, remove, add };
pub const DiffLine = struct { op: Op, line: []const u8 };

pub fn diffOps(a: std.mem.Allocator, old: []const u8, new: []const u8) []DiffLine {
    var ol: std.ArrayList([]const u8) = .empty;
    var nl: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |l| ol.append(a, l) catch {};
    var it2 = std.mem.splitScalar(u8, new, '\n');
    while (it2.next()) |l| nl.append(a, l) catch {};
    const m = ol.items.len;
    const n = nl.items.len;
    const dp = a.alloc(usize, (m + 1) * (n + 1)) catch return &[_]DiffLine{};
    for (dp) |*v| v.* = 0;
    var i: usize = m;
    while (i > 0) : (i -= 1) {
        var j: usize = n;
        while (j > 0) : (j -= 1) {
            const idx = (i - 1) * (n + 1) + (j - 1);
            if (std.mem.eql(u8, ol.items[i - 1], nl.items[j - 1])) dp[idx] = dp[i * (n + 1) + j] + 1 else dp[idx] = @max(dp[i * (n + 1) + (j - 1)], dp[(i - 1) * (n + 1) + j]);
        }
    }
    var out: std.ArrayList(DiffLine) = .empty;
    var x: usize = 0;
    var y: usize = 0;
    while (x < m and y < n) {
        if (std.mem.eql(u8, ol.items[x], nl.items[y])) {
            out.append(a, .{ .op = .context, .line = ol.items[x] }) catch {};
            x += 1;
            y += 1;
        } else if (dp[(x + 1) * (n + 1) + y] >= dp[x * (n + 1) + (y + 1)]) {
            out.append(a, .{ .op = .remove, .line = ol.items[x] }) catch {};
            x += 1;
        } else {
            out.append(a, .{ .op = .add, .line = nl.items[y] }) catch {};
            y += 1;
        }
    }
    while (x < m) : (x += 1) out.append(a, .{ .op = .remove, .line = ol.items[x] }) catch {};
    while (y < n) : (y += 1) out.append(a, .{ .op = .add, .line = nl.items[y] }) catch {};
    return out.toOwnedSlice(a) catch &[_]DiffLine{};
}

pub fn opName(op: Op) []const u8 {
    return switch (op) {
        .context => "context",
        .remove => "remove",
        .add => "add",
    };
}

pub fn printDiff(ctx: *ctx_mod.Ctx, old: []const u8, new: []const u8) void {
    const ops = diffOps(ctx.a, old, new);
    for (ops) |dl| switch (dl.op) {
        .context => ctx.emit("  {s}\n", .{dl.line}),
        .remove => ctx.emit("{s}- {s}{s}\n", .{ ctx.k(colors.RED), dl.line, ctx.k(colors.RESET) }),
        .add => ctx.emit("{s}+ {s}{s}\n", .{ ctx.k(colors.GREEN), dl.line, ctx.k(colors.RESET) }),
    };
}

const testing = std.testing;

fn runDiff(a: std.mem.Allocator, old: []const u8, new: []const u8) []const u8 {
    var ctx = ctx_mod.Ctx{ .a = a, .color = false };
    printDiff(&ctx, old, new);
    return ctx.buf.toOwnedSlice(a) catch "";
}

test "printDiff identical input yields all context lines, no +/-" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = runDiff(arena.allocator(), "alpha\nbeta\n", "alpha\nbeta\n");
    try testing.expect(std.mem.indexOf(u8, out, "- ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "+ ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "  alpha") != null);
}

test "printDiff single-line replace emits both - and +" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = runDiff(arena.allocator(), "alpha\nbeta\n", "alpha\ngamma\n");
    try testing.expect(std.mem.indexOf(u8, out, "- beta") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+ gamma") != null);
}

test "printDiff pure addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = runDiff(arena.allocator(), "alpha\n", "alpha\nbeta\n");
    try testing.expect(std.mem.indexOf(u8, out, "+ beta") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- ") == null);
}

test "diffOps single-line replace returns context+remove+add" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = diffOps(arena.allocator(), "alpha\nbeta\n", "alpha\ngamma\n");
    // Trailing newline → split yields one trailing empty string each.
    // Look for the meaningful ops by scanning.
    var saw_ctx = false;
    var saw_rm = false;
    var saw_add = false;
    for (ops) |dl| switch (dl.op) {
        .context => if (std.mem.eql(u8, dl.line, "alpha")) {
            saw_ctx = true;
        },
        .remove => if (std.mem.eql(u8, dl.line, "beta")) {
            saw_rm = true;
        },
        .add => if (std.mem.eql(u8, dl.line, "gamma")) {
            saw_add = true;
        },
    };
    try testing.expect(saw_ctx);
    try testing.expect(saw_rm);
    try testing.expect(saw_add);
}

test "opName maps the enum to canonical JSON strings" {
    try testing.expectEqualStrings("context", opName(.context));
    try testing.expectEqualStrings("remove", opName(.remove));
    try testing.expectEqualStrings("add", opName(.add));
}
