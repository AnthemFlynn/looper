//! POSIX interop: the single `@cImport` for libc, plus `runCapture` /
//! `runInherit` over fork/execvp/waitpid. Deliberately bypasses
//! `std.process.Child` to sidestep `std.Io` churn in Zig 0.16.
const std = @import("std");

pub const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("time.h");
});

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

pub fn nowEpoch() i64 {
    return @intCast(c.time(null));
}

pub const RunResult = struct { code: i32, out: []u8 };

pub fn runCapture(a: std.mem.Allocator, argv: []const []const u8, stdin_bytes: ?[]const u8) !RunResult {
    var inpipe: [2]c_int = .{ -1, -1 };
    var outpipe: [2]c_int = undefined;
    if (c.pipe(&outpipe) != 0) return error.Pipe;
    if (stdin_bytes != null) if (c.pipe(&inpipe) != 0) return error.Pipe;
    const cargv = try a.alloc([*c]u8, argv.len + 1);
    for (argv, 0..) |arg, i| cargv[i] = (try a.dupeZ(u8, arg)).ptr;
    cargv[argv.len] = null;
    const pid = c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = c.dup2(outpipe[1], 1);
        _ = c.close(outpipe[0]);
        _ = c.close(outpipe[1]);
        if (stdin_bytes != null) {
            _ = c.dup2(inpipe[0], 0);
            _ = c.close(inpipe[0]);
            _ = c.close(inpipe[1]);
        }
        _ = c.execvp(cargv[0], cargv.ptr);
        c._exit(127);
    }
    _ = c.close(outpipe[1]);
    if (stdin_bytes) |b| {
        _ = c.close(inpipe[0]);
        if (b.len > 0) _ = c.write(inpipe[1], b.ptr, b.len);
        _ = c.close(inpipe[1]);
    }
    var out: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = c.read(outpipe[0], &tmp, tmp.len);
        if (n <= 0) break;
        try out.appendSlice(a, tmp[0..@intCast(n)]);
    }
    _ = c.close(outpipe[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const code: i32 = if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else -1;
    return .{ .code = code, .out = try out.toOwnedSlice(a) };
}

pub fn runInherit(a: std.mem.Allocator, argv: []const []const u8) !i32 {
    const cargv = try a.alloc([*c]u8, argv.len + 1);
    for (argv, 0..) |arg, i| cargv[i] = (try a.dupeZ(u8, arg)).ptr;
    cargv[argv.len] = null;
    const pid = c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = c.execvp(cargv[0], cargv.ptr);
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else -1;
}

pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = c.write(2, s.ptr, s.len);
}
