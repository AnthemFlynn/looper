//! Pure timezone-value module. `TzInfo` carries the offset, abbrev, and
//! provenance — enough to render any UTC epoch as a wall-clock string in
//! that zone, and to label the result so the reader knows whether
//! they're seeing the target's clock or a controller-local fallback.
//!
//! No I/O. The remote-probe side lives in `tz_probe.zig`.

const std = @import("std");
const posix = @import("posix.zig");
const c = posix.c;

pub const Source = enum {
    /// Resolved from the controller's local time. The user IS in this
    /// zone, so renders need no "(controller-local)" qualifier.
    controller_local,
    /// Probed from a remote target via ssh. Authoritative for the
    /// target; renders show the target's wall clock with the target's
    /// abbrev (e.g. "SGT").
    target_probed,
    /// Probe attempted and failed. Renders happen in controller TZ but
    /// MUST carry "(controller-local)" so the user isn't misled into
    /// reading them as target time.
    controller_fallback,
};

pub const TzInfo = struct {
    offset_secs: i32,
    abbrev: []const u8,
    source: Source,
};

/// Read the controller's current TZ via libc.
pub fn controllerTz(a: std.mem.Allocator) TzInfo {
    return controllerTzAt(a, posix.nowEpoch());
}

/// Pinned-epoch variant for tests and for the rare case where we want
/// the TZ as-of a specific instant (DST boundaries). Uses the libc
/// localtime/timegm difference trick to derive the offset — sidesteps
/// the `tm_gmtoff` / `tm_zone` glibc/BSD extensions that aren't
/// portably exposed without `_DEFAULT_SOURCE` / `_BSD_SOURCE` feature
/// macros. `strftime("%Z")` is POSIX-standard.
pub fn controllerTzAt(a: std.mem.Allocator, ts_utc: i64) TzInfo {
    var tt: c.time_t = @intCast(ts_utc);
    var local_tm: c.struct_tm = undefined;
    _ = c.localtime_r(&tt, &local_tm);
    // Treat the local broken-down time AS IF it were UTC; `timegm`
    // returns the epoch that would correspond. Difference from the real
    // UTC epoch IS the offset (positive east of UTC).
    var fake_utc = local_tm;
    fake_utc.tm_isdst = 0;
    const fake = c.timegm(&fake_utc);
    const offset: i32 = @intCast(@as(i64, @intCast(fake)) - ts_utc);

    var buf: [16]u8 = undefined;
    const n = c.strftime(&buf, buf.len, "%Z", &local_tm);
    const abbrev_raw = buf[0..n];
    const abbrev = if (abbrev_raw.len > 0)
        a.dupe(u8, abbrev_raw) catch fallbackAbbrev(a, offset)
    else
        fallbackAbbrev(a, offset);

    return .{ .offset_secs = offset, .abbrev = abbrev, .source = .controller_local };
}

/// Canonical snake_case names for JSON emit. Don't use `@tagName` on
/// `Source` directly — it returns the Zig identifier, but the contract
/// for `--json` is stability across refactors, not whatever the enum
/// happens to be named today.
pub fn sourceStr(s: Source) []const u8 {
    return switch (s) {
        .controller_local => "controller_local",
        .target_probed => "target_probed",
        .controller_fallback => "controller_fallback",
    };
}

/// `UTC±HH:MM` format. Used when `%Z` produces nothing (musl in some
/// configurations) or when a probe returns only `+%z` without a usable
/// `%Z` abbrev.
pub fn fallbackAbbrev(a: std.mem.Allocator, offset_secs: i32) []const u8 {
    const sign: u8 = if (offset_secs < 0) '-' else '+';
    const abs: u32 = @intCast(if (offset_secs < 0) -offset_secs else offset_secs);
    const h = @divTrunc(abs, 3600);
    const m = @divTrunc(@mod(abs, 3600), 60);
    return std.fmt.allocPrint(a, "UTC{c}{d:0>2}:{d:0>2}", .{ sign, h, m }) catch "UTC";
}

/// Strict parser for the wire shape `±HHMM\tABBR[\r\n]*`. Lives in
/// `tz.zig` (not `tz_probe.zig`) because the piggybacked path in
/// `crontab/target.zig` needs it too, and routing both call sites
/// through `tz_probe` would make `target` depend on a module that
/// already depends on `target` (`sshArgvPrefix`).
///
/// Conservative ABBR charset (`[A-Za-z0-9+\-]`, max 8 chars) rejects
/// locale-translated `%Z` output (e.g. Cyrillic) so a non-C locale on
/// the remote falls back to controller-local labeling rather than
/// injecting garbage characters into our output.
pub fn parseDateProbe(a: std.mem.Allocator, stdout: []const u8) ?TzInfo {
    const line = std.mem.trimEnd(u8, stdout, " \t\r\n");
    if (line.len < 7) return null; // "+HHMM\tA" minimum
    if (line[0] != '+' and line[0] != '-') return null;
    var i: usize = 1;
    while (i < 5) : (i += 1) if (!std.ascii.isDigit(line[i])) return null;
    if (line[5] != '\t') return null;
    const abbrev = line[6..];
    if (abbrev.len == 0 or abbrev.len > 8) return null;
    for (abbrev) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-') return null;
    }
    const sign: i32 = if (line[0] == '-') -1 else 1;
    const hh: i32 = @intCast((line[1] - '0') * 10 + (line[2] - '0'));
    const mm: i32 = @intCast((line[3] - '0') * 10 + (line[4] - '0'));
    if (hh > 14 or mm >= 60) return null; // sanity bound; max real TZ is +14:00
    const offset = sign * (hh * 3600 + mm * 60);
    return .{
        .offset_secs = offset,
        .abbrev = a.dupe(u8, abbrev) catch return null,
        .source = .target_probed,
    };
}

const testing = std.testing;

test "controllerTzAt returns a usable TzInfo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Can't override TZ from inside the test without env+tzset gymnastics;
    // sanity-check that we get non-empty abbrev and the right source.
    const info = controllerTzAt(arena.allocator(), 1_700_000_000);
    try testing.expect(info.abbrev.len > 0);
    try testing.expectEqual(Source.controller_local, info.source);
    // Sanity: a real TZ offset is between -12h and +14h.
    try testing.expect(info.offset_secs >= -12 * 3600);
    try testing.expect(info.offset_secs <= 14 * 3600);
}

test "fallbackAbbrev formats UTC offset correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("UTC+08:00", fallbackAbbrev(arena.allocator(), 8 * 3600));
    try testing.expectEqualStrings("UTC-05:30", fallbackAbbrev(arena.allocator(), -5 * 3600 - 30 * 60));
    try testing.expectEqualStrings("UTC+00:00", fallbackAbbrev(arena.allocator(), 0));
    try testing.expectEqualStrings("UTC+14:00", fallbackAbbrev(arena.allocator(), 14 * 3600));
}

test "parseDateProbe accepts well-formed SGT output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = parseDateProbe(arena.allocator(), "+0800\tSGT\n").?;
    try testing.expectEqual(@as(i32, 8 * 3600), info.offset_secs);
    try testing.expectEqualStrings("SGT", info.abbrev);
    try testing.expectEqual(Source.target_probed, info.source);
}

test "parseDateProbe accepts negative offset and trailing CRLF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = parseDateProbe(arena.allocator(), "-0530\tIST\r\n").?;
    try testing.expectEqual(@as(i32, -(5 * 3600 + 30 * 60)), info.offset_secs);
    try testing.expectEqualStrings("IST", info.abbrev);
}

test "parseDateProbe rejects missing tab" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parseDateProbe(arena.allocator(), "+0800 SGT\n") == null);
}

test "parseDateProbe rejects locale-translated abbrev (Cyrillic bytes)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parseDateProbe(arena.allocator(), "+0800\t\xd0\x9a\xd0\xa0\xd0\x90\xd0\xa2\n") == null);
}

test "parseDateProbe rejects garbage and out-of-range values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parseDateProbe(arena.allocator(), "abcde\tFOO\n") == null);
    try testing.expect(parseDateProbe(arena.allocator(), "+9999\tFOO\n") == null);
    try testing.expect(parseDateProbe(arena.allocator(), "+0860\tFOO\n") == null);
    try testing.expect(parseDateProbe(arena.allocator(), "") == null);
    try testing.expect(parseDateProbe(arena.allocator(), "+08") == null);
}

test "parseDateProbe accepts 4-letter abbrev like AEDT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = parseDateProbe(arena.allocator(), "+1100\tAEDT\n").?;
    try testing.expectEqualStrings("AEDT", info.abbrev);
    try testing.expectEqual(@as(i32, 11 * 3600), info.offset_secs);
}

test "parseDateProbe accepts numeric-style abbrev like +12" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = parseDateProbe(arena.allocator(), "+1200\t+12\n").?;
    try testing.expectEqualStrings("+12", info.abbrev);
}

test "sourceStr maps each variant to canonical JSON name" {
    try testing.expectEqualStrings("controller_local", sourceStr(.controller_local));
    try testing.expectEqualStrings("target_probed", sourceStr(.target_probed));
    try testing.expectEqualStrings("controller_fallback", sourceStr(.controller_fallback));
}
