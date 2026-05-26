//! Cross-caller advisory locking around the read-modify-write window
//! (v0.2 #8). Two `looper` processes that mutate the same crontab must
//! serialize, or one's writes will be lost when the other reads stale
//! content before re-serializing.
//!
//! Mechanism: `flock(LOCK_EX)` on a per-target sidecar lock file. The
//! file just has to exist long enough to hold the kernel-side lock —
//! we never read or write its contents.
//!
//! Scope in v0.2:
//!  - **File targets**: lock file lives at `<path>.lock`, next to the
//!    crontab file itself. Same-directory writability is implied by
//!    the user being able to write the crontab.
//!  - **Local crontab**: lock file under `$XDG_STATE_HOME/looper/locks/
//!    local[__user].lock`. Same state dir layout the runs store uses,
//!    so we don't sprout a new top-level directory.
//!  - **Remote targets**: not in v0.2. `flock` would have to ride an
//!    advisory sentinel file written via ssh, with the connection
//!    holding the lock; the acceptance script doesn't exercise this and
//!    the design is meaningfully more complex than the local case.
//!    Issue #8 leaves room for a later iteration.
//!
//! The lock is best-effort: if we can't open the lock file (permissions,
//! read-only fs, etc.) the operation still proceeds — surfacing a hard
//! failure would regress users who never had concurrent writers anyway.
//! Concurrent agents on a writable fs are the supported case; everyone
//! else gets the old behavior.

const std = @import("std");
const posix = @import("posix.zig");
const target_mod = @import("crontab/target.zig");
const c = posix.c;

const Target = target_mod.Target;

/// Opaque handle for an acquired lock. Always call `release()` (or use
/// `defer lock.release()` at the call site). `release()` is safe to
/// call on a no-op lock (fd == -1) — it just returns.
pub const Lock = struct {
    fd: c_int = -1,
    pub fn release(self: *Lock) void {
        if (self.fd < 0) return;
        _ = c.flock(self.fd, posix.LOCK_UN);
        _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// Acquire an exclusive lock for the target's mutating window. Returns a
/// `Lock` value the caller is responsible for releasing. On any failure
/// (no lock path, can't open, can't flock) returns a no-op `Lock{}` —
/// the caller proceeds without the safety net, matching pre-v0.2
/// behavior so single-writer use cases never break.
pub fn acquire(a: std.mem.Allocator, t: Target) Lock {
    const lock_path = lockPathFor(a, t) orelse return .{};
    // 0o600: lock file is private to the user that opened it; no need
    // for group/world access.
    const pz = a.dupeZ(u8, lock_path) catch return .{};
    const fd = c.open(pz.ptr, c.O_RDWR | c.O_CREAT, @as(c_uint, 0o600));
    if (fd < 0) return .{};
    // Blocking acquire — concurrent callers wait their turn. This is
    // exactly the contract the acceptance test exercises: spawn two
    // adds, both block until the lock is theirs, both writes land.
    if (c.flock(fd, posix.LOCK_EX) != 0) {
        _ = c.close(fd);
        return .{};
    }
    return .{ .fd = fd };
}

/// Derive the lock file path for a target. Returns null for kinds where
/// locking isn't supported in v0.2 (remote) or where we can't compute a
/// stable per-target path (no XDG/HOME for the local case).
fn lockPathFor(a: std.mem.Allocator, t: Target) ?[]const u8 {
    switch (t.kind) {
        .file => return std.fmt.allocPrint(a, "{s}.lock", .{t.path}) catch null,
        .local => {
            const dir = locksDir(a) orelse return null;
            // mkdir -p the locks directory; ignore EEXIST. If the mkdir
            // fails for any other reason, the subsequent open will fail
            // and acquire() falls back to the no-op lock.
            ensureDir(a, dir);
            const name = if (t.user.len > 0)
                std.fmt.allocPrint(a, "{s}/local__{s}.lock", .{ dir, t.user }) catch return null
            else
                std.fmt.allocPrint(a, "{s}/local.lock", .{dir}) catch return null;
            return name;
        },
        .remote => return null,
    }
}

fn locksDir(a: std.mem.Allocator) ?[]const u8 {
    if (posix.getenv("XDG_STATE_HOME")) |x| {
        return std.fmt.allocPrint(a, "{s}/looper/locks", .{x}) catch null;
    }
    if (posix.getenv("HOME")) |h| {
        return std.fmt.allocPrint(a, "{s}/.local/state/looper/locks", .{h}) catch null;
    }
    return null;
}

fn ensureDir(a: std.mem.Allocator, path: []const u8) void {
    // Walk the path, mkdir each component. Tolerates EEXIST — that's
    // the goal of this helper. Real failures (permission, ENOTDIR)
    // surface later when the lock file open fails.
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        const piece = a.dupeZ(u8, path[0..i]) catch return;
        _ = c.mkdir(piece.ptr, @as(c_uint, 0o700));
    }
}

const testing = std.testing;

test "acquire returns no-op lock for remote target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t: Target = .{ .kind = .remote, .host = "nas" };
    var lk = acquire(arena.allocator(), t);
    defer lk.release();
    try testing.expectEqual(@as(c_int, -1), lk.fd);
}

test "acquire on a file target creates the lock file and returns an fd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "/tmp/looper-lock-test-{x}.crontab", .{posix.nowEpoch()});
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    defer _ = c.unlink((a.dupeZ(u8, lock_path) catch unreachable).ptr);
    const t: Target = .{ .kind = .file, .path = path };
    var lk = acquire(a, t);
    try testing.expect(lk.fd >= 0);
    lk.release();
    try testing.expectEqual(@as(c_int, -1), lk.fd);
    // Lock file should exist on disk.
    const pz = try a.dupeZ(u8, lock_path);
    const fd = c.open(pz.ptr, c.O_RDONLY);
    try testing.expect(fd >= 0);
    _ = c.close(fd);
}

test "release on a no-op lock is safe" {
    var lk: Lock = .{};
    lk.release(); // shouldn't crash
    lk.release(); // double-release is also fine
}
