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
            try argv.append(a, "ssh");
            try argv.append(a, "-o");
            try argv.append(a, "BatchMode=yes");
            try argv.append(a, t.host);
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
            try argv.append(a, "ssh");
            try argv.append(a, "-o");
            try argv.append(a, "BatchMode=yes");
            try argv.append(a, t.host);
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
