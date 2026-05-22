//! Crontab backup snapshots in $XDG_STATE_HOME/looper/backups/<slug>/.
//! Every mutation calls `doBackup` before writing; `restore` reads the
//! newest snapshot back.
const std = @import("std");
const posix = @import("../posix.zig");
const c = posix.c;
const target_mod = @import("target.zig");
const Target = target_mod.Target;

pub fn mkdirP(a: std.mem.Allocator, path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) if (i == path.len or path[i] == '/') {
        const seg = a.dupeZ(u8, path[0..i]) catch return;
        _ = c.mkdir(seg.ptr, 0o755);
    };
}

pub fn stateDir(a: std.mem.Allocator) []const u8 {
    if (posix.getenv("XDG_STATE_HOME")) |x| return std.fmt.allocPrint(a, "{s}/looper", .{x}) catch ".";
    return std.fmt.allocPrint(a, "{s}/.local/state/looper", .{posix.getenv("HOME") orelse "."}) catch ".";
}

pub fn utcStamp(a: std.mem.Allocator) []const u8 {
    var tt: c.time_t = @intCast(posix.nowEpoch());
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&tt, &tm);
    return std.fmt.allocPrint(a, "{d}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    }) catch "stamp";
}

pub fn backupDir(a: std.mem.Allocator, t: Target) []const u8 {
    return std.fmt.allocPrint(a, "{s}/backups/{s}", .{ stateDir(a), t.slug(a) }) catch ".";
}

pub fn doBackup(a: std.mem.Allocator, t: Target, content: []const u8) ?[]const u8 {
    const dir = backupDir(a, t);
    mkdirP(a, dir);
    const path = std.fmt.allocPrint(a, "{s}/{s}.crontab", .{ dir, utcStamp(a) }) catch return null;
    target_mod.writeFileAll(a, path, content) catch return null;
    return path;
}

pub fn newestBackup(a: std.mem.Allocator, t: Target) ?[]const u8 {
    const dir = backupDir(a, t);
    const dz = a.dupeZ(u8, dir) catch return null;
    const d = c.opendir(dz.ptr) orelse return null;
    defer _ = c.closedir(d);
    var best_name: ?[]const u8 = null;
    while (true) {
        const ent = c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".crontab")) continue;
        if (best_name == null or std.mem.order(u8, name, best_name.?) == .gt) best_name = a.dupe(u8, name) catch best_name;
    }
    const bn = best_name orelse return null;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, bn }) catch null;
}
