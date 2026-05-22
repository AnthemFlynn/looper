//! Target backends: local crontab, remote crontab over ssh, or a plain
//! file. One switch dispatch per operation — three known compile-time
//! backends, no trait/vtable indirection.
const std = @import("std");
const posix = @import("../posix.zig");
const c = posix.c;

pub const TargetKind = enum { local, remote, file };

pub const Target = struct {
    kind: TargetKind,
    host: []const u8 = "",
    user: []const u8 = "",
    path: []const u8 = "",
    pub fn label(self: Target, a: std.mem.Allocator) []const u8 {
        return switch (self.kind) {
            .local => if (self.user.len > 0) (std.fmt.allocPrint(a, "local (user {s})", .{self.user}) catch "local") else "local",
            .remote => if (self.user.len > 0) (std.fmt.allocPrint(a, "{s} (user {s})", .{ self.host, self.user }) catch self.host) else self.host,
            .file => std.fmt.allocPrint(a, "file:{s}", .{self.path}) catch "file",
        };
    }
    pub fn slug(self: Target, a: std.mem.Allocator) []const u8 {
        const raw = switch (self.kind) {
            .local => "local",
            .remote => self.host,
            .file => self.path,
        };
        var b: std.ArrayList(u8) = .empty;
        for (raw) |ch| b.append(a, if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') ch else '_') catch {};
        if (self.user.len > 0) {
            b.appendSlice(a, "__") catch {};
            for (self.user) |ch| b.append(a, if (std.ascii.isAlphanumeric(ch)) ch else '_') catch {};
        }
        return b.toOwnedSlice(a) catch raw;
    }
};

pub const BackendError = error{ Unavailable, WriteFailed };

/// Common ssh argv prefix for every remote invocation:
///   ssh -o BatchMode=yes -o ConnectTimeout=10 <host>
/// BatchMode prevents interactive credential prompts that would hang a
/// non-tty invocation; ConnectTimeout caps fleet runs against dead hosts
/// at ~10s per target instead of the OS default (often 60-120s).
pub fn sshArgvPrefix(a: std.mem.Allocator, host: []const u8) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "ssh");
    try argv.append(a, "-o");
    try argv.append(a, "BatchMode=yes");
    try argv.append(a, "-o");
    try argv.append(a, "ConnectTimeout=10");
    try argv.append(a, host);
    return argv.toOwnedSlice(a);
}

pub fn readFileAll(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try a.dupeZ(u8, path);
    const fd = c.open(pz.ptr, c.O_RDONLY);
    if (fd < 0) return "";
    defer _ = c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n <= 0) break;
        try out.appendSlice(a, tmp[0..@intCast(n)]);
    }
    return out.toOwnedSlice(a);
}

pub fn writeFileAll(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const pz = try a.dupeZ(u8, path);
    const fd = c.open(pz.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return BackendError.WriteFailed;
    defer _ = c.close(fd);
    if (data.len > 0) {
        if (c.write(fd, data.ptr, data.len) < 0) return BackendError.WriteFailed;
    }
}

pub fn readCrontab(a: std.mem.Allocator, t: Target) ![]u8 {
    switch (t.kind) {
        .file => return readFileAll(a, t.path),
        .local => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, "crontab");
            if (t.user.len > 0) {
                try argv.append(a, "-u");
                try argv.append(a, t.user);
            }
            try argv.append(a, "-l");
            const r = try posix.runCapture(a, argv.items, null);
            if (r.code == 127) return BackendError.Unavailable;
            return r.out;
        },
        .remote => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(a, try sshArgvPrefix(a, t.host));
            try argv.append(a, "crontab");
            if (t.user.len > 0) {
                try argv.append(a, "-u");
                try argv.append(a, t.user);
            }
            try argv.append(a, "-l");
            const r = try posix.runCapture(a, argv.items, null);
            if (r.code == 255 or r.code == 127) return BackendError.Unavailable;
            return r.out;
        },
    }
}

pub fn writeCrontab(a: std.mem.Allocator, t: Target, data: []const u8) !void {
    switch (t.kind) {
        .file => return writeFileAll(a, t.path, data),
        .local => {
            const tmpl = try a.dupeZ(u8, "/tmp/looper.XXXXXX");
            const fd = c.mkstemp(tmpl.ptr);
            if (fd < 0) return BackendError.WriteFailed;
            if (data.len > 0) _ = c.write(fd, data.ptr, data.len);
            _ = c.close(fd);
            const path = std.mem.span(tmpl.ptr);
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, "crontab");
            if (t.user.len > 0) {
                try argv.append(a, "-u");
                try argv.append(a, t.user);
            }
            try argv.append(a, path);
            const r = try posix.runCapture(a, argv.items, null);
            _ = c.unlink(tmpl.ptr);
            if (r.code != 0) return BackendError.WriteFailed;
        },
        .remote => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(a, try sshArgvPrefix(a, t.host));
            try argv.append(a, "crontab");
            if (t.user.len > 0) {
                try argv.append(a, "-u");
                try argv.append(a, t.user);
            }
            try argv.append(a, "-");
            const r = try posix.runCapture(a, argv.items, data);
            if (r.code != 0) return BackendError.WriteFailed;
        },
    }
}

// ─── readCrontabAndTz ─────────────────────────────────────────────────────────
// Piggybacks the timezone probe onto the same ssh round-trip that runs
// `crontab -l`. Splits remote stdout on a sentinel line; pre-sentinel is
// crontab content, post-sentinel is the probe payload. Zero extra ssh
// round-trips for the common case of `ls`/`show` against `--all`.

const tz_mod = @import("../tz.zig");
pub const TzInfo = tz_mod.TzInfo;

/// Random-looking sentinel chosen so it cannot collide with a valid cron
/// line: leading `=` fails `splitScheduleCommand`, and even if a user's
/// crontab contained this exact bytes, the split takes it as the boundary
/// rather than treating it as cron content.
pub const TZ_PROBE_SENTINEL = "=== LOOPER_TZ_PROBE_a9f3 ===";

pub const ReadResult = struct {
    content: []u8,
    /// `null` when the target wasn't a remote (caller resolves controller
    /// TZ for local/file) OR when the remote probe didn't make it back
    /// (caller falls back to controller TZ with `.controller_fallback`).
    tz: ?TzInfo,
};

pub fn readCrontabAndTz(a: std.mem.Allocator, t: Target, probe_tz: bool) !ReadResult {
    if (!probe_tz or t.kind != .remote) {
        const content = try readCrontab(a, t);
        return .{ .content = content, .tz = null };
    }
    switch (t.kind) {
        .file, .local => unreachable, // gated by probe_tz check above
        .remote => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(a, try sshArgvPrefix(a, t.host));
            // `|| true` swallows the "no crontab for user" non-zero exit
            // so the probe still runs. Leading `\n` ensures the sentinel
            // is on its own line even when crontab output is empty or
            // lacks a trailing newline.
            const remote_cmd = if (t.user.len > 0)
                try std.fmt.allocPrint(
                    a,
                    "crontab -l -u {s} 2>/dev/null || true; printf '\\n{s}\\n%s\\t%s\\n' \"$(date +%z)\" \"$(date +%Z)\"",
                    .{ t.user, TZ_PROBE_SENTINEL },
                )
            else
                try std.fmt.allocPrint(
                    a,
                    "crontab -l 2>/dev/null || true; printf '\\n{s}\\n%s\\t%s\\n' \"$(date +%z)\" \"$(date +%Z)\"",
                    .{TZ_PROBE_SENTINEL},
                );
            try argv.append(a, remote_cmd);
            const r = try posix.runCapture(a, argv.items, null);
            if (r.code == 255 or r.code == 127) return BackendError.Unavailable;
            return splitProbeResult(a, r.out);
        },
    }
}

/// Pulled out for inline testability without a real ssh round-trip.
pub fn splitProbeResult(a: std.mem.Allocator, stdout: []const u8) !ReadResult {
    const split_idx = std.mem.indexOf(u8, stdout, TZ_PROBE_SENTINEL) orelse {
        // Sentinel missing → ssh succeeded but the remote shell didn't
        // reach the printf (restricted shell, weird PATH, etc.). Treat
        // as a plain crontab read so the caller falls back to controller
        // TZ rather than failing the whole command.
        return .{ .content = try a.dupe(u8, stdout), .tz = null };
    };
    var content_end = split_idx;
    // Strip the single \n we prepended to the sentinel.
    if (content_end > 0 and stdout[content_end - 1] == '\n') content_end -= 1;
    const content = try a.dupe(u8, stdout[0..content_end]);
    const after = stdout[split_idx + TZ_PROBE_SENTINEL.len ..];
    const probe_text = std.mem.trimStart(u8, after, "\r\n");
    const tz = tz_mod.parseDateProbe(a, probe_text);
    return .{ .content = content, .tz = tz };
}

const testing = std.testing;

test "sshArgvPrefix produces canonical batch-safe argv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try sshArgvPrefix(arena.allocator(), "pi@nas");
    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("ssh", argv[0]);
    try testing.expectEqualStrings("-o", argv[1]);
    try testing.expectEqualStrings("BatchMode=yes", argv[2]);
    try testing.expectEqualStrings("-o", argv[3]);
    try testing.expectEqualStrings("ConnectTimeout=10", argv[4]);
    try testing.expectEqualStrings("pi@nas", argv[5]);
}

test "Target.slug sanitizes non-alphanumeric chars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t1: Target = .{ .kind = .remote, .host = "pi@nas.local" };
    try testing.expectEqualStrings("pi_nas.local", t1.slug(arena.allocator()));
    const t2: Target = .{ .kind = .local, .user = "ops" };
    try testing.expectEqualStrings("local__ops", t2.slug(arena.allocator()));
}

test "Target.label distinguishes the three kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("local", (Target{ .kind = .local }).label(a));
    try testing.expectEqualStrings("nas", (Target{ .kind = .remote, .host = "nas" }).label(a));
    try testing.expectEqualStrings("file:/tmp/x", (Target{ .kind = .file, .path = "/tmp/x" }).label(a));
}

test "splitProbeResult separates crontab content and probe payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two cron lines, sentinel, probe.
    const fixture =
        "0 3 * * * /usr/local/bin/backup.sh\n" ++
        "@reboot /opt/start.sh\n" ++
        "\n" ++ TZ_PROBE_SENTINEL ++ "\n" ++
        "+0800\tSGT\n";
    const r = try splitProbeResult(a, fixture);
    try testing.expectEqualStrings(
        "0 3 * * * /usr/local/bin/backup.sh\n@reboot /opt/start.sh\n",
        r.content,
    );
    try testing.expect(r.tz != null);
    try testing.expectEqualStrings("SGT", r.tz.?.abbrev);
    try testing.expectEqual(@as(i32, 8 * 3600), r.tz.?.offset_secs);
}

test "splitProbeResult handles empty crontab + probe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = "\n" ++ TZ_PROBE_SENTINEL ++ "\n-0500\tEST\n";
    const r = try splitProbeResult(a, fixture);
    try testing.expectEqualStrings("", r.content);
    try testing.expectEqualStrings("EST", r.tz.?.abbrev);
}

test "splitProbeResult missing sentinel falls through cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Restricted shell — printf never ran. Caller should fall back to
    // controller TZ rather than fail.
    const fixture = "@daily /opt/x.sh\n";
    const r = try splitProbeResult(a, fixture);
    try testing.expectEqualStrings("@daily /opt/x.sh\n", r.content);
    try testing.expect(r.tz == null);
}

test "splitProbeResult sentinel with malformed probe payload yields content + null tz" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = "@daily /opt/x.sh\n\n" ++ TZ_PROBE_SENTINEL ++ "\ngarbage-not-a-probe\n";
    const r = try splitProbeResult(a, fixture);
    try testing.expectEqualStrings("@daily /opt/x.sh\n", r.content);
    try testing.expect(r.tz == null);
}
