//! Shared context passed to every command — allocator, flags, output buffer.
//! Also houses the process-wide exit-code accumulator that drives the final
//! exit value when running across multiple targets.
const std = @import("std");
const posix = @import("posix.zig");
const c = posix.c;

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const CYAN = "\x1b[36m";

pub const Ctx = struct {
    a: std.mem.Allocator,
    color: bool = false,
    json: bool = false,
    dry_run: bool = false,
    yes: bool = false,
    quiet: bool = false,
    buf: std.ArrayList(u8) = .empty,
    /// First-failure wins. Stays 0 until something fails; subsequent
    /// failures don't overwrite. `main` reads this at end-of-run.
    exit_code: u8 = 0,
    pub fn emit(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.a, fmt, args) catch return;
        self.buf.appendSlice(self.a, s) catch {};
    }
    pub fn flush(self: *Ctx) void {
        if (self.buf.items.len == 0) return;
        _ = c.write(1, self.buf.items.ptr, self.buf.items.len);
        self.buf.clearRetainingCapacity();
    }
    pub fn k(self: *Ctx, code: []const u8) []const u8 {
        return if (self.color) code else "";
    }
    /// Mark this run as failed. Records the first failure code only.
    pub fn fail(self: *Ctx, code: u8) void {
        if (self.exit_code == 0) self.exit_code = code;
    }
};

pub fn aw(a: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(a, fmt, args) catch return;
    list.appendSlice(a, s) catch {};
}

const testing = std.testing;

test "Ctx.fail records first failure only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = Ctx{ .a = arena.allocator() };
    try testing.expectEqual(@as(u8, 0), ctx.exit_code);
    ctx.fail(2);
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
    ctx.fail(1); // subsequent failure does not overwrite
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "Ctx.k returns empty string when color off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = Ctx{ .a = arena.allocator(), .color = false };
    try testing.expectEqualStrings("", ctx.k(RED));
    ctx.color = true;
    try testing.expectEqualStrings(RED, ctx.k(RED));
}

test "Ctx.emit appends to buf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = Ctx{ .a = arena.allocator() };
    ctx.emit("hello {s} {d}\n", .{ "world", 42 });
    try testing.expectEqualStrings("hello world 42\n", ctx.buf.items);
}
