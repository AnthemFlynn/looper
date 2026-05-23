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
    @cInclude("signal.h"); // kill(2), SIGTERM/SIGKILL — needed by _exec timeout
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
    // 2 KB is well under PIPE_BUF on every platform, so a single
    // write(2) practically never returns short here — but routing
    // through writeAll keeps the "every write loops" invariant
    // explicit and means a future caller widening the buffer doesn't
    // silently re-introduce partial writes.
    writeAll(2, s) catch {};
}

// ---------------------------------------------------------------------------
// Self-path resolution — where is the looper binary on disk right now?
// Embedded into cron lines emitted by `looper add --capture` and
// `looper once`, so cron knows what to invoke when the job fires.
// Cross-platform via builtin.os.tag; v1 ships Linux + macOS, Windows
// has a clear TODO branch ready for when looper grows native Windows
// support (cron itself is Unix, but WSL users benefit immediately).
// ---------------------------------------------------------------------------

const builtin = @import("builtin");

/// macOS-specific: `_NSGetExecutablePath` is declared in `<mach-o/dyld.h>`,
/// which transitively pulls in mach headers that Zig 0.16's translate-c
/// chokes on (static-assert mismatches inside `mach_msg_*_trailer_t`).
/// Declare the symbol directly — dyld is always linked into Mach-O
/// binaries, so no extra link step is needed.
///
/// Signature per Apple's man page:
///   int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
/// Returns 0 on success, -1 if `*bufsize` was too small (and updates
/// it to the required size).
extern fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// Returns the absolute path to the currently-running binary. Null when
/// the platform doesn't provide a stable mechanism (or the call fails).
/// The result is heap-allocated via the supplied allocator.
///
/// Implementation per platform:
/// - Linux: `readlink("/proc/self/exe", …)` — symlink the kernel maintains.
/// - macOS: `_NSGetExecutablePath(buf, &len)` — may return a path that's
///   not canonical (could contain `..` or symlinks); we resolve via
///   `realpath(3)` to match the Linux behavior.
/// - Other (FreeBSD, NetBSD, Windows): TODO. Returns null for now.
pub fn looperPath(a: std.mem.Allocator) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            // PATH_MAX on Linux is 4096; 8 KiB is generous and matches
            // what util-linux tools use for readlink targets.
            var buf: [8192]u8 = undefined;
            const n = c.readlink("/proc/self/exe", &buf, buf.len);
            if (n <= 0) return null;
            return a.dupe(u8, buf[0..@intCast(n)]) catch null;
        },
        .macos => {
            // _NSGetExecutablePath fills `buf` and reports required size
            // when `bufsize` is too small. PATH_MAX on Darwin is 1024.
            var raw: [4096]u8 = undefined;
            var size: u32 = raw.len;
            if (_NSGetExecutablePath(&raw, &size) != 0) return null;
            // raw may contain `..` or symlink components — realpath(3)
            // canonicalizes so the value embedded in the cron line is
            // stable regardless of how looper was invoked.
            var resolved: [4096]u8 = undefined;
            const rp = c.realpath(&raw, &resolved);
            if (rp == null) {
                // realpath failed (extremely unlikely for our own
                // executable) — fall back to the raw NSGet value.
                const len = std.mem.indexOfSentinel(u8, 0, @ptrCast(&raw));
                return a.dupe(u8, raw[0..len]) catch null;
            }
            const len = std.mem.indexOfSentinel(u8, 0, @ptrCast(&resolved));
            return a.dupe(u8, resolved[0..len]) catch null;
        },
        // TODO(windows): GetModuleFileNameW(NULL, buf, MAX_PATH) via
        // <windows.h>, then WideCharToMultiByte UTF-16 → UTF-8.
        // Blocked until looper grows broader Windows support — cron
        // itself doesn't exist on native Windows, so this only matters
        // for WSL (which already uses the Linux branch above).
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// POSIX shell single-quoting — the only quoting we use for embedding a
// user-supplied command string into a shell command line.
//
// Rule: wrap the string in single quotes, replace every literal `'`
// with the four-character sequence `'\''` (close-quote, escaped quote,
// reopen-quote). The shell parses the escaped quote as a literal `'`
// embedded between two single-quoted runs. This is portable across
// every POSIX shell (sh, bash, dash, zsh, ksh) and the only edge case
// to know about — no `$`, backslash, or backtick handling needed
// because everything between single quotes is literal.
//
// Output is always safe to drop verbatim into a shell command line.
// ---------------------------------------------------------------------------

pub fn shellQuote(a: std.mem.Allocator, s: []const u8) []const u8 {
    // Pre-compute output length: 2 (outer quotes) + s.len + 3 * (count of `'`).
    var quotes: usize = 0;
    for (s) |ch| if (ch == '\'') {
        quotes += 1;
    };
    const out_len = 2 + s.len + 3 * quotes;
    var out = a.alloc(u8, out_len) catch return "";
    out[0] = '\'';
    var off: usize = 1;
    for (s) |ch| {
        if (ch == '\'') {
            // close-quote, escaped quote, re-open-quote.
            out[off] = '\'';
            out[off + 1] = '\\';
            out[off + 2] = '\'';
            out[off + 3] = '\'';
            off += 4;
        } else {
            out[off] = ch;
            off += 1;
        }
    }
    out[off] = '\'';
    return out;
}

/// Inverse of `shellQuote`. Accepts the exact format we emit: outer
/// single quotes, with embedded literal `'` represented as the four-byte
/// sequence `'\''`. Returns null on malformed input (missing outer quote,
/// truncated escape, etc.) so callers can fall back to degraded display
/// rather than silently corrupting the user's command.
pub fn shellUnquote(a: std.mem.Allocator, s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[0] != '\'' or s[s.len - 1] != '\'') return null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    const end = s.len - 1;
    while (i < end) {
        if (i + 3 < s.len and s[i] == '\'' and s[i + 1] == '\\' and s[i + 2] == '\'' and s[i + 3] == '\'') {
            // `'\''` → single literal `'`.
            out.append(a, '\'') catch return null;
            i += 4;
            continue;
        }
        // Any other `'` before the closing position means malformed input.
        if (s[i] == '\'') return null;
        out.append(a, s[i]) catch return null;
        i += 1;
    }
    return out.toOwnedSlice(a) catch null;
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

test "looperPath returns an absolute path on supported OSes" {
    // The test binary itself is what we're querying — its path will be
    // somewhere under .zig-cache. We don't pin the exact path (it's
    // hashed), only the contract: absolute, non-empty, and the file
    // actually exists on disk (open(2) succeeds).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = looperPath(a) orelse {
        // Platforms we haven't implemented yet return null; the test
        // becomes vacuous there rather than a hard failure, so the
        // suite still passes on FreeBSD / Windows / etc.
        return;
    };
    try testing.expect(path.len > 0);
    try testing.expect(path[0] == '/');
    // The path must point at something that exists.
    const pz = try a.dupeZ(u8, path);
    const fd = c.open(pz.ptr, c.O_RDONLY);
    try testing.expect(fd >= 0);
    _ = c.close(fd);
}

test "shellQuote wraps simple strings in single quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("'hello'", shellQuote(a, "hello"));
    try testing.expectEqualStrings("'echo hi'", shellQuote(a, "echo hi"));
    try testing.expectEqualStrings("''", shellQuote(a, ""));
}

test "shellQuote escapes embedded single quotes via close-open trick" {
    // The classic POSIX idiom: `'` inside the string becomes `'\''`,
    // which closes the surrounding quote, inserts a literal `'`, and
    // reopens. Net result in the shell: a single literal `'`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("'it'\\''s me'", shellQuote(a, "it's me"));
    try testing.expectEqualStrings("''\\''leading'", shellQuote(a, "'leading"));
    try testing.expectEqualStrings("'trailing'\\'''", shellQuote(a, "trailing'"));
    try testing.expectEqualStrings("'a'\\''b'\\''c'", shellQuote(a, "a'b'c"));
}

test "shellQuote leaves other shell metacharacters as literal" {
    // Single-quoting is the whole game — `$`, `\`, backtick all stay
    // literal because they're inside `'...'`. This is exactly what we
    // want: the wrapped command sees those characters as data, not as
    // shell expansion triggers in the outer (cron-invoked) shell.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("'$HOME'", shellQuote(a, "$HOME"));
    try testing.expectEqualStrings("'echo `pwd`'", shellQuote(a, "echo `pwd`"));
    try testing.expectEqualStrings("'\\n'", shellQuote(a, "\\n"));
}

test "shellQuote round-trips through /bin/sh -c" {
    // Functional test: shellQuote's output, prepended with `echo `
    // and run through sh -c, must produce the original string.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const originals = [_][]const u8{
        "hello",
        "echo hi",
        "it's me",
        "a'b'c",
        "$HOME",
        "echo `pwd`",
        "\\n is literal",
        "mix 'of' \"types\" and $dollars",
    };
    for (originals) |orig| {
        const quoted = shellQuote(a, orig);
        const cmd = try std.fmt.allocPrint(a, "printf %s {s}", .{quoted});
        const r = try runCapture(a, &[_][]const u8{ "/bin/sh", "-c", cmd }, null);
        try testing.expectEqual(@as(i32, 0), r.code);
        try testing.expectEqualStrings(orig, r.out);
    }
}

test "shellUnquote inverts shellQuote for every shape we emit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const originals = [_][]const u8{
        "hello",
        "echo hi",
        "it's me",
        "a'b'c",
        "$HOME",
        "echo `pwd`",
        "\\n is literal",
        "",
    };
    for (originals) |orig| {
        const quoted = shellQuote(a, orig);
        const back = shellUnquote(a, quoted) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings(orig, back);
    }
}

test "shellUnquote returns null on malformed inputs" {
    // Anything that wasn't produced by shellQuote — missing outer
    // quote, unescaped inner `'`, etc. — surfaces as null so the
    // caller can fall back rather than silently producing garbage.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?[]const u8, null), shellUnquote(a, "no-quotes"));
    try testing.expectEqual(@as(?[]const u8, null), shellUnquote(a, "'unterminated"));
    try testing.expectEqual(@as(?[]const u8, null), shellUnquote(a, "unterminated'"));
    // An unescaped `'` inside the quoted region isn't something our
    // shellQuote ever emits — reject it rather than guessing.
    try testing.expectEqual(@as(?[]const u8, null), shellUnquote(a, "'bad ' here'"));
}
