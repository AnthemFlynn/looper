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
