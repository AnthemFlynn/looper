//! Unified-style diff for --dry-run. LCS-based; not optimized for huge
//! files but a crontab maxes out at hundreds of lines.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");

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
            if (std.mem.eql(u8, ol.items[i - 1], nl.items[j - 1])) dp[idx] = dp[i * (n + 1) + j] + 1
            else dp[idx] = @max(dp[i * (n + 1) + (j - 1)], dp[(i - 1) * (n + 1) + j]);
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
            ctx.emit("{s}- {s}{s}\n", .{ ctx.k(ctx_mod.RED), ol.items[x], ctx.k(ctx_mod.RESET) });
            x += 1;
        } else {
            ctx.emit("{s}+ {s}{s}\n", .{ ctx.k(ctx_mod.GREEN), nl.items[y], ctx.k(ctx_mod.RESET) });
            y += 1;
        }
    }
    while (x < m) : (x += 1) ctx.emit("{s}- {s}{s}\n", .{ ctx.k(ctx_mod.RED), ol.items[x], ctx.k(ctx_mod.RESET) });
    while (y < n) : (y += 1) ctx.emit("{s}+ {s}{s}\n", .{ ctx.k(ctx_mod.GREEN), nl.items[y], ctx.k(ctx_mod.RESET) });
}
