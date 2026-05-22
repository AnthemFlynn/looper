//! Unified-style diff for --dry-run. LCS-based; not optimized for huge
//! files but a crontab maxes out at hundreds of lines.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const colors = @import("colors.zig");

pub fn printDiff(ctx: *ctx_mod.Ctx, old: []const u8, new: []const u8) void {
    const a = ctx.a;
    var ol: std.ArrayList([]const u8) = .empty;
    var nl: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |l| ol.append(a, l) catch {};
    var it2 = std.mem.splitScalar(u8, new, '\n');
    while (it2.next()) |l| nl.append(a, l) catch {};
    const m = ol.items.len;
    const n = nl.items.len;
    const dp = a.alloc(usize, (m + 1) * (n + 1)) catch return;
    for (dp) |*x| x.* = 0;
    var i: usize = m;
    while (i > 0) : (i -= 1) {
        var j: usize = n;
        while (j > 0) : (j -= 1) {
            const idx = (i - 1) * (n + 1) + (j - 1);
            if (std.mem.eql(u8, ol.items[i - 1], nl.items[j - 1])) dp[idx] = dp[i * (n + 1) + j] + 1 else dp[idx] = @max(dp[i * (n + 1) + (j - 1)], dp[(i - 1) * (n + 1) + j]);
        }
    }
    var x: usize = 0;
    var y: usize = 0;
    while (x < m and y < n) {
        if (std.mem.eql(u8, ol.items[x], nl.items[y])) {
            ctx.emit("  {s}\n", .{ol.items[x]});
            x += 1;
            y += 1;
        } else if (dp[(x + 1) * (n + 1) + y] >= dp[x * (n + 1) + (y + 1)]) {
            ctx.emit("{s}- {s}{s}\n", .{ ctx.k(colors.RED), ol.items[x], ctx.k(colors.RESET) });
            x += 1;
        } else {
            ctx.emit("{s}+ {s}{s}\n", .{ ctx.k(colors.GREEN), nl.items[y], ctx.k(colors.RESET) });
            y += 1;
        }
    }
    while (x < m) : (x += 1) ctx.emit("{s}- {s}{s}\n", .{ ctx.k(colors.RED), ol.items[x], ctx.k(colors.RESET) });
    while (y < n) : (y += 1) ctx.emit("{s}+ {s}{s}\n", .{ ctx.k(colors.GREEN), nl.items[y], ctx.k(colors.RESET) });
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
