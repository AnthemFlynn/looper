//! Remote-target timezone probe + per-run cache. Pairs with `tz.zig`
//! (pure values + parser). The parser lives in `tz.zig` because the
//! piggybacked path in `crontab/target.zig` needs it too — see comment
//! in `tz.parseDateProbe` for why.
//!
//! Cache scope is per-run only. TZs change rarely but persistence
//! introduces invalidation problems for the tiny benefit of saving one
//! ssh round-trip per run.

const std = @import("std");
const posix = @import("posix.zig");
const tz_mod = @import("tz.zig");
const target_mod = @import("crontab/target.zig");

const TzInfo = tz_mod.TzInfo;

/// The shell snippet we run on the remote. Identical bytes are also
/// appended after the sentinel by `target.readCrontabAndTz` so the
/// parser is shared.
pub const REMOTE_DATE_CMD = "printf '%s\\t%s\\n' \"$(date +%z)\" \"$(date +%Z)\"";

/// Standalone probe — opens its own ssh connection. Production reads
/// piggyback the probe onto `crontab -l` via `readCrontabAndTz` to
/// avoid a second round-trip; this function exists for `doctor`, where
/// the probe IS the check rather than a side effect.
pub fn probeRemote(a: std.mem.Allocator, host: []const u8) ?TzInfo {
    const prefix = target_mod.sshArgvPrefix(a, host) catch return null;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, prefix) catch return null;
    argv.append(a, REMOTE_DATE_CMD) catch return null;
    const r = posix.runCapture(a, argv.items, null) catch return null;
    if (r.code != 0) return null;
    return tz_mod.parseDateProbe(a, r.out);
}

/// Per-run TZ cache keyed by host string. Linear scan because realistic
/// `--all` fleets are O(10s) of hosts; a hashmap would weigh more than
/// the lookup it would save.
pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        host: []const u8,
        info: TzInfo,
    };

    pub fn lookup(self: *const Cache, host: []const u8) ?TzInfo {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.host, host)) return e.info;
        return null;
    }

    pub fn insert(self: *Cache, a: std.mem.Allocator, host: []const u8, info: TzInfo) void {
        if (self.lookup(host) != null) return;
        self.entries.append(a, .{
            .host = a.dupe(u8, host) catch return,
            .info = info,
        }) catch {};
    }
};

const testing = std.testing;

test "Cache round-trips by host and rejects duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cache: Cache = .{};
    try testing.expect(cache.lookup("nas") == null);
    const info: TzInfo = .{ .offset_secs = 8 * 3600, .abbrev = "SGT", .source = .target_probed };
    cache.insert(a, "nas", info);
    const got = cache.lookup("nas").?;
    try testing.expectEqual(@as(i32, 8 * 3600), got.offset_secs);
    try testing.expectEqualStrings("SGT", got.abbrev);
    cache.insert(a, "nas", info);
    try testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    cache.insert(a, "media", .{ .offset_secs = 0, .abbrev = "UTC", .source = .target_probed });
    try testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try testing.expectEqualStrings("UTC", cache.lookup("media").?.abbrev);
}

test "Cache.lookup misses an unknown host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cache: Cache = .{};
    try testing.expect(cache.lookup("never-inserted") == null);
}
