//! Terminal display primitives: padding, truncation, JSON escape,
//! slug generation, plus the tty confirmation prompt.
const std = @import("std");
const posix = @import("../posix.zig");
const c = posix.c;
const ctx_mod = @import("../ctx.zig");
const model = @import("../crontab/model.zig");

pub fn termWidth() usize {
    if (posix.getenv("COLUMNS")) |cols| {
        if (std.fmt.parseInt(usize, cols, 10) catch null) |w| return w;
    }
    return 100;
}

pub fn padTo(a: std.mem.Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len >= w) return s;
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(a, s) catch return s;
    var i: usize = s.len;
    while (i < w) : (i += 1) b.append(a, ' ') catch {};
    return b.toOwnedSlice(a) catch s;
}

pub fn truncEllipsis(a: std.mem.Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len <= w or w <= 1) return s;
    return std.fmt.allocPrint(a, "{s}\xe2\x80\xa6", .{s[0 .. w - 1]}) catch s;
}

pub fn jsonEsc(a: std.mem.Allocator, s: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '"' => b.appendSlice(a, "\\\"") catch {},
        '\\' => b.appendSlice(a, "\\\\") catch {},
        '\n' => b.appendSlice(a, "\\n") catch {},
        '\t' => b.appendSlice(a, "\\t") catch {},
        else => b.append(a, ch) catch {},
    };
    return b.toOwnedSlice(a) catch s;
}

pub fn slugFromCommand(a: std.mem.Allocator, cmd: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    var base = it.next() orelse "job";
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |p| base = base[p + 1 ..];
    var b: std.ArrayList(u8) = .empty;
    for (base) |ch| if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') b.append(a, std.ascii.toLower(ch)) catch {};
    if (b.items.len == 0) return "job";
    return b.toOwnedSlice(a) catch "job";
}

pub fn slugUnique(a: std.mem.Allocator, ct: *model.Crontab, cmd: []const u8) []const u8 {
    const base = slugFromCommand(a, cmd);
    var cand = base;
    var n: usize = 2;
    while (ct.findIndex(cand) != null) : (n += 1) cand = std.fmt.allocPrint(a, "{s}-{d}", .{ base, n }) catch base;
    return cand;
}

pub fn confirm(ctx: *ctx_mod.Ctx, comptime fmt: []const u8, args: anytype) bool {
    if (ctx.yes) return true;
    if (c.isatty(0) == 0) {
        posix.eprint("looper: refusing without a tty; pass --yes\n", .{});
        return false;
    }
    posix.eprint(fmt ++ " [y/N] ", args);
    var b: [16]u8 = undefined;
    const n = c.read(0, &b, b.len);
    if (n <= 0) return false;
    return b[0] == 'y' or b[0] == 'Y';
}

const testing = std.testing;

test "slugFromCommand strips path and lowercases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("python3", slugFromCommand(arena.allocator(), "/usr/bin/python3 -m foo"));
    try testing.expectEqualStrings("backup", slugFromCommand(arena.allocator(), "/usr/local/bin/Backup --db"));
}

test "slugFromCommand empty/non-alphanum fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("job", slugFromCommand(arena.allocator(), ""));
}

test "slugUnique appends -2 on collision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ct = @import("../crontab/model.zig").Crontab{};
    try ct.items.append(a, .{ .job = .{ .id = "backup", .enabled = true, .schedule = "0 3 * * *", .command = "x" } });
    try testing.expectEqualStrings("backup-2", slugUnique(a, &ct, "/usr/local/bin/backup --db"));
}

test "padTo pads short strings; passes long through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ab   ", padTo(arena.allocator(), "ab", 5));
    try testing.expectEqualStrings("hello", padTo(arena.allocator(), "hello", 3));
}

test "jsonEsc escapes the four currently-handled chars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\\\"b", jsonEsc(arena.allocator(), "a\"b"));
    try testing.expectEqualStrings("a\\\\b", jsonEsc(arena.allocator(), "a\\b"));
    try testing.expectEqualStrings("a\\nb", jsonEsc(arena.allocator(), "a\nb"));
    try testing.expectEqualStrings("a\\tb", jsonEsc(arena.allocator(), "a\tb"));
}
