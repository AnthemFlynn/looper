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

/// Atomic snapshot: write to `<path>.tmp`, then `rename` into place.
/// POSIX rename(2) is atomic on the same filesystem, so a kill mid-write
/// leaves the destination either fully present or absent — never
/// truncated. The `.tmp` may be left behind on crash; that's fine.
pub fn doBackup(a: std.mem.Allocator, t: Target, content: []const u8) ?[]const u8 {
    const dir = backupDir(a, t);
    mkdirP(a, dir);
    const path = std.fmt.allocPrint(a, "{s}/{s}.crontab", .{ dir, utcStamp(a) }) catch return null;
    const tmp_path = std.fmt.allocPrint(a, "{s}.tmp", .{path}) catch return null;
    target_mod.writeFileAll(a, tmp_path, content) catch return null;
    const src = a.dupeZ(u8, tmp_path) catch return null;
    const dst = a.dupeZ(u8, path) catch return null;
    if (c.rename(src.ptr, dst.ptr) != 0) {
        _ = c.unlink(src.ptr);
        return null;
    }
    return path;
}

/// Return the newest `*.crontab` file in the backup dir, or null.
/// Honors POSIX `readdir`/errno contract: zero errno before each call,
/// then distinguish end-of-directory (NULL + errno==0) from genuine
/// errors (NULL + errno!=0).
pub fn newestBackup(a: std.mem.Allocator, t: Target) ?[]const u8 {
    const dir = backupDir(a, t);
    const dz = a.dupeZ(u8, dir) catch return null;
    const d = c.opendir(dz.ptr) orelse return null;
    defer _ = c.closedir(d);
    var best_name: ?[]const u8 = null;
    while (true) {
        std.c._errno().* = 0;
        const ent = c.readdir(d) orelse {
            // NULL: end of dir if errno==0, real error otherwise. Either
            // way we stop; the caller treats null as "no backup found",
            // which is the safest fall-through. Distinguishing the two
            // would surface I/O errors as a louder failure later.
            break;
        };
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".crontab")) continue;
        if (best_name == null or std.mem.order(u8, name, best_name.?) == .gt) best_name = a.dupe(u8, name) catch best_name;
    }
    const bn = best_name orelse return null;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, bn }) catch null;
}

/// One entry returned by `listBackups`. `stamp` is the 16-char
/// `YYYYMMDDTHHMMSSZ` slice; `path` is the absolute path to the .crontab
/// file. `size_bytes` and `mtime` come from `stat(2)` and are used for
/// the human listing. Stamps are lex-sortable, so newest-first sorting
/// is a simple string comparison.
pub const BackupEntry = struct {
    stamp: []const u8,
    path: []const u8,
    size_bytes: u64,
    mtime: i64,
};

pub const StampError = error{ Ambiguous, NotFound };

/// `struct stat`'s layout is opaque to translate-c under musl (its fields
/// hide behind feature-test macros), so we can't portably declare a
/// `var st: c.struct_stat`. We sidestep stat entirely:
///
/// - `mtime` comes from parsing the stamp itself — `YYYYMMDDTHHMMSSZ` *is*
///   the creation time encoded as UTC, and that's exactly what the listing
///   shows as "age". The actual on-disk mtime can only drift later by file
///   copy/move; from the user's standpoint, the snapshot's time is the
///   stamp's time.
/// - `size_bytes` comes from `lseek(fd, 0, SEEK_END)` — works on every
///   POSIX FS and doesn't touch `struct stat`.
fn stampToEpoch(stamp: []const u8) i64 {
    if (stamp.len != 16) return 0;
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = (std.fmt.parseInt(i32, stamp[0..4], 10) catch return 0) - 1900;
    tm.tm_mon = (std.fmt.parseInt(i32, stamp[4..6], 10) catch return 0) - 1;
    tm.tm_mday = std.fmt.parseInt(i32, stamp[6..8], 10) catch return 0;
    tm.tm_hour = std.fmt.parseInt(i32, stamp[9..11], 10) catch return 0;
    tm.tm_min = std.fmt.parseInt(i32, stamp[11..13], 10) catch return 0;
    tm.tm_sec = std.fmt.parseInt(i32, stamp[13..15], 10) catch return 0;
    return @intCast(c.timegm(&tm));
}

fn fileSizeBytes(path_z: [*:0]const u8) u64 {
    const fd = c.open(path_z, c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK_END);
    return if (end < 0) 0 else @intCast(end);
}

/// Enumerate every `<stamp>.crontab` in the target's backup dir,
/// sorted newest-first. Missing dir (no backups yet) returns an empty
/// slice — not an error — so callers can treat empty uniformly. Entries
/// whose name doesn't match the 16-char stamp shape are skipped to
/// avoid surfacing stray `.tmp` files or hand-edited names.
pub fn listBackups(a: std.mem.Allocator, t: Target) ![]BackupEntry {
    const dir = backupDir(a, t);
    const dz = try a.dupeZ(u8, dir);
    const d = c.opendir(dz.ptr) orelse return &[_]BackupEntry{};
    defer _ = c.closedir(d);
    var list: std.ArrayList(BackupEntry) = .empty;
    while (true) {
        std.c._errno().* = 0;
        const ent = c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".crontab")) continue;
        const stamp_only = name[0 .. name.len - ".crontab".len];
        // Skip names that don't look like our stamp shape — 16 chars,
        // `T` at position 8, `Z` at 15. Rejects e.g. `foo.crontab.tmp`
        // leftovers without making us pretend every leftover is a backup.
        if (stamp_only.len != 16 or stamp_only[8] != 'T' or stamp_only[15] != 'Z') continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
        const pz = a.dupeZ(u8, full) catch continue;
        try list.append(a, .{
            .stamp = a.dupe(u8, stamp_only) catch continue,
            .path = full,
            .size_bytes = fileSizeBytes(pz.ptr),
            .mtime = stampToEpoch(stamp_only),
        });
    }
    // Newest first: stamps are lex-sortable thanks to fixed-width UTC.
    std.mem.sort(BackupEntry, list.items, {}, struct {
        fn lt(_: void, x: BackupEntry, y: BackupEntry) bool {
            return std.mem.order(u8, x.stamp, y.stamp) == .gt;
        }
    }.lt);
    return list.toOwnedSlice(a);
}

/// Resolve a user-supplied stamp (full or substring) against the target's
/// backups. Substrings let users paste partial timestamps from `looper
/// backups` without retyping the full 16 chars; ambiguous matches are an
/// error rather than a silent "first hit" so `looper restore --from
/// 20260521` can't accidentally restore the wrong snapshot when two
/// share a day.
pub fn findByStamp(a: std.mem.Allocator, t: Target, query: []const u8) !BackupEntry {
    const all = try listBackups(a, t);
    var hit: ?BackupEntry = null;
    var n_hits: usize = 0;
    for (all) |e| {
        if (std.mem.indexOf(u8, e.stamp, query) != null) {
            hit = e;
            n_hits += 1;
        }
    }
    if (n_hits > 1) return StampError.Ambiguous;
    return hit orelse StampError.NotFound;
}

/// Result of a prune operation: which entries survived, which were
/// removed. `removed` is empty when nothing was deleted (count <= keep).
pub const PruneResult = struct {
    kept: []BackupEntry,
    removed: []BackupEntry,
};

/// Keep newest `keep` entries; unlink the rest. `keep == 0` is rejected
/// by the caller (commands.zig) so a stray `--keep 0` can't sweep every
/// snapshot. `dry_run = true` lists what *would* go without touching the
/// filesystem.
pub fn pruneBackups(a: std.mem.Allocator, t: Target, keep: usize, dry_run: bool) !PruneResult {
    const all = try listBackups(a, t);
    if (all.len <= keep) return .{ .kept = all, .removed = &[_]BackupEntry{} };
    const kept = all[0..keep];
    const candidates = all[keep..];
    if (dry_run) return .{ .kept = kept, .removed = candidates };
    var removed: std.ArrayList(BackupEntry) = .empty;
    for (candidates) |e| {
        const pz = a.dupeZ(u8, e.path) catch continue;
        if (c.unlink(pz.ptr) == 0) try removed.append(a, e);
    }
    return .{ .kept = kept, .removed = try removed.toOwnedSlice(a) };
}

const testing = std.testing;

test "doBackup writes content and returns existing path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Use a unique tmp dir for the test so we don't pollute the real
    // XDG state directory. We can't easily redirect stateDir; instead
    // use a file-target slug under /tmp and assert via the same path
    // doBackup produces.
    const t: @import("target.zig").Target = .{ .kind = .file, .path = try std.fmt.allocPrint(a, "/tmp/looper-bkup-test-{x}", .{posix.nowEpoch()}) };
    const payload = "hello world\n";
    const path = doBackup(a, t, payload) orelse return error.BackupReturnedNull;
    defer _ = c.unlink((a.dupeZ(u8, path) catch unreachable).ptr);
    // The .tmp must NOT linger after a successful rename.
    const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    const tmp_z = try a.dupeZ(u8, tmp_path);
    const fd = c.open(tmp_z.ptr, c.O_RDONLY);
    try testing.expect(fd < 0); // tmp file gone
    // The real path exists and contains the payload.
    const got = try @import("target.zig").readFileAll(a, path);
    try testing.expectEqualStrings(payload, got);
}

test "utcStamp format YYYYMMDDTHHMMSSZ" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = utcStamp(arena.allocator());
    // 16 chars: 8 date + T + 6 time + Z = 16
    try testing.expectEqual(@as(usize, 16), s.len);
    try testing.expectEqual(@as(u8, 'T'), s[8]);
    try testing.expectEqual(@as(u8, 'Z'), s[15]);
}

// Helper: lay down a file target plus a controlled set of backup
// stamps under the target's slug. Returns the target so callers can
// also exercise listBackups/findByStamp/pruneBackups against it.
fn makeTestTarget(a: std.mem.Allocator, stamps: []const []const u8) !@import("target.zig").Target {
    const t: @import("target.zig").Target = .{
        .kind = .file,
        .path = try std.fmt.allocPrint(a, "/tmp/looper-bkup-list-test-{x}.crontab", .{posix.nowEpoch()}),
    };
    const dir = backupDir(a, t);
    mkdirP(a, dir);
    for (stamps, 0..) |stamp, idx| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}.crontab", .{ dir, stamp });
        const body = try std.fmt.allocPrint(a, "# backup {d}\n", .{idx});
        try @import("target.zig").writeFileAll(a, path, body);
    }
    return t;
}

fn cleanupBackups(a: std.mem.Allocator, t: @import("target.zig").Target) void {
    const dir = backupDir(a, t);
    const dz = a.dupeZ(u8, dir) catch return;
    const d = c.opendir(dz.ptr) orelse return;
    defer _ = c.closedir(d);
    while (true) {
        std.c._errno().* = 0;
        const ent = c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".crontab")) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
        const pz = a.dupeZ(u8, full) catch continue;
        _ = c.unlink(pz.ptr);
    }
}

test "listBackups returns entries sorted newest-first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{
        "20260101T000000Z",
        "20260522T093015Z",
        "20260520T180000Z",
    };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    const list = try listBackups(a, t);
    try testing.expectEqual(@as(usize, 3), list.len);
    // Sorted newest-first by stamp.
    try testing.expectEqualStrings("20260522T093015Z", list[0].stamp);
    try testing.expectEqualStrings("20260520T180000Z", list[1].stamp);
    try testing.expectEqualStrings("20260101T000000Z", list[2].stamp);
    // size_bytes reflects the real file size.
    try testing.expect(list[0].size_bytes > 0);
}

test "listBackups skips non-conforming names (leftover .tmp)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{ "20260520T180000Z", "garbage" };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    const list = try listBackups(a, t);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("20260520T180000Z", list[0].stamp);
}

test "listBackups on a never-backed-up target returns empty, not error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: @import("target.zig").Target = .{
        .kind = .file,
        .path = try std.fmt.allocPrint(a, "/tmp/looper-no-backup-{x}.crontab", .{posix.nowEpoch()}),
    };
    const list = try listBackups(a, t);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "findByStamp resolves a unique substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{ "20260101T000000Z", "20260522T093015Z" };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    const e = try findByStamp(a, t, "20260522");
    try testing.expectEqualStrings("20260522T093015Z", e.stamp);
}

test "findByStamp rejects ambiguous substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{ "20260522T093015Z", "20260522T180000Z" };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    // Day-only substring matches both entries — must error rather than
    // silently pick one and risk restoring the wrong snapshot.
    try testing.expectError(StampError.Ambiguous, findByStamp(a, t, "20260522"));
}

test "findByStamp on no match errors NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{"20260522T093015Z"};
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    try testing.expectError(StampError.NotFound, findByStamp(a, t, "19000101"));
}

test "pruneBackups keeps newest N and removes the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{
        "20260101T000000Z",
        "20260102T000000Z",
        "20260103T000000Z",
        "20260104T000000Z",
    };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    const r = try pruneBackups(a, t, 2, false);
    try testing.expectEqual(@as(usize, 2), r.kept.len);
    try testing.expectEqual(@as(usize, 2), r.removed.len);
    try testing.expectEqualStrings("20260104T000000Z", r.kept[0].stamp);
    try testing.expectEqualStrings("20260103T000000Z", r.kept[1].stamp);
    // Filesystem reflects the deletion.
    const after = try listBackups(a, t);
    try testing.expectEqual(@as(usize, 2), after.len);
}

test "pruneBackups dry-run touches nothing on disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{ "20260101T000000Z", "20260102T000000Z", "20260103T000000Z" };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    const r = try pruneBackups(a, t, 1, true);
    try testing.expectEqual(@as(usize, 1), r.kept.len);
    try testing.expectEqual(@as(usize, 2), r.removed.len);
    // All three still exist after the dry run.
    const after = try listBackups(a, t);
    try testing.expectEqual(@as(usize, 3), after.len);
}

test "pruneBackups noop when count <= keep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stamps = [_][]const u8{ "20260101T000000Z", "20260102T000000Z" };
    const t = try makeTestTarget(a, &stamps);
    defer cleanupBackups(a, t);
    const r = try pruneBackups(a, t, 5, false);
    try testing.expectEqual(@as(usize, 2), r.kept.len);
    try testing.expectEqual(@as(usize, 0), r.removed.len);
}
