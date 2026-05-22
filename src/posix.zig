//! POSIX interop: the single `@cImport` for libc, plus `runCapture` /
//! `runInherit` over fork/execvp/waitpid. Deliberately bypasses
//! `std.process.Child` to sidestep `std.Io` churn in Zig 0.16.
const std = @import("std");

pub const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h"); // rename(2)
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

/// Loop `write(2)` until `bytes` is fully written or an error occurs.
/// `write(2)` can return a short count; for a single non-looped call,
/// payloads larger than `PIPE_BUF` (~4–64KB) may be silently truncated.
/// Returns `error.WriteFailed` on real I/O error (including `EPIPE` —
/// the peer closed the read side, so further writes will not succeed).
///
/// Caveat: in `runCapture`'s stdin path, the parent calls this BEFORE
/// it starts reading the child's stdout. If the child both reads stdin
/// AND writes to stdout, large payloads can deadlock — child fills the
/// stdout pipe (~16–64KB) and blocks while parent is still in
/// `writeAll`. Crontab clients (`crontab -`, `ssh ... crontab -`) are
/// stdin-only and don't trigger this; the limit only matters if a
/// future caller pipes a large payload into a duplex child.
pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed; // peer hung up / no progress
        written += @intCast(n);
    }
}

pub const RunResult = struct { code: i32, out: []u8 };

/// Cap on bytes captured from a child's stdout. A crontab fits in a few
/// kilobytes; 16 MiB is generous for any sane workload and bounds the
/// damage a misbehaving subprocess can do to our memory footprint.
pub const MAX_CAPTURE_BYTES: usize = 16 * 1024 * 1024;

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
        if (b.len > 0) writeAll(inpipe[1], b) catch {
            // child may have exited early; we still close the pipe and
            // let `waitpid` surface its real exit code below.
        };
        _ = c.close(inpipe[1]);
    }
    var out: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    var truncated = false;
    while (true) {
        const n = c.read(outpipe[0], &tmp, tmp.len);
        if (n <= 0) break;
        const got: usize = @intCast(n);
        if (out.items.len + got > MAX_CAPTURE_BYTES) {
            // Drain the rest into the bit bucket so the child's write
            // side doesn't block on a full pipe, then wait for it.
            truncated = true;
            const remaining = MAX_CAPTURE_BYTES - out.items.len;
            try out.appendSlice(a, tmp[0..remaining]);
            while (c.read(outpipe[0], &tmp, tmp.len) > 0) {}
            break;
        }
        try out.appendSlice(a, tmp[0..got]);
    }
    _ = c.close(outpipe[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if (truncated) return error.OutputTooLarge;
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

const testing = std.testing;

test "runCapture stdin payload larger than PIPE_BUF writes fully" {
    // Build a 256KB payload; PIPE_BUF on Darwin is 512, on Linux 4096 —
    // anything past that is where un-looped write(2) silently truncated
    // before the writeAll fix.
    //
    // Use `cat > /dev/null` (not bare `cat`) so the child reads stdin
    // without producing stdout, sidestepping the documented duplex-
    // pipe deadlock in runCapture. The test verifies the writeAll
    // loop completes for a large payload; we cross-check size via
    // `wc -c` against the child's perspective.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const size = 256 * 1024;
    const payload = try a.alloc(u8, size);
    for (payload, 0..) |*ch, i| ch.* = 'A' + @as(u8, @intCast(i % 26));
    const r = try runCapture(a, &[_][]const u8{ "/bin/sh", "-c", "wc -c > /tmp/looper-bytes-test.out" }, payload);
    try testing.expectEqual(@as(i32, 0), r.code);
    // Read the count the child wrote and verify it matches our payload.
    const got = try @import("crontab/target.zig").readFileAll(a, "/tmp/looper-bytes-test.out");
    defer _ = c.unlink((a.dupeZ(u8, "/tmp/looper-bytes-test.out") catch unreachable).ptr);
    const trimmed = std.mem.trim(u8, got, " \t\n");
    const n = std.fmt.parseInt(usize, trimmed, 10) catch return error.UnexpectedWcOutput;
    try testing.expectEqual(size, n);
}

test "runCapture exit code surfaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCapture(arena.allocator(), &[_][]const u8{ "/bin/sh", "-c", "exit 42" }, null);
    try testing.expectEqual(@as(i32, 42), r.code);
}

test "runCapture nonexistent binary returns 127" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCapture(arena.allocator(), &[_][]const u8{"/this/does/not/exist"}, null);
    try testing.expectEqual(@as(i32, 127), r.code);
}

test "runCapture caps output at MAX_CAPTURE_BYTES" {
    // Ask `head` to emit just over the cap. `head -c <N>` is portable
    // across BSD/Darwin/Linux. The child will be SIGPIPE-d once we
    // stop reading; runCapture handles that by draining and waiting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const over = MAX_CAPTURE_BYTES + 1024;
    const arg = try std.fmt.allocPrint(arena.allocator(), "head -c {d} /dev/zero", .{over});
    const result = runCapture(arena.allocator(), &[_][]const u8{ "/bin/sh", "-c", arg }, null);
    try testing.expectError(error.OutputTooLarge, result);
}

test "runCapture passes through outputs well under the cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCapture(arena.allocator(), &[_][]const u8{ "/bin/sh", "-c", "head -c 1024 /dev/zero" }, null);
    try testing.expectEqual(@as(usize, 1024), r.out.len);
}
