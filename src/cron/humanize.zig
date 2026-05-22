//! cron expression → English. Used by `ls`, `show`, `explain`, and
//! the "interpreted as" disclosure after NLP compilation.
const std = @import("std");
const sched = @import("schedule.zig");

fn appendName(a: std.mem.Allocator, out: *std.ArrayList(u8), idx: usize, tok: []const u8) void {
    const num: ?u32 = sched.nameToNum(idx, tok) orelse (std.fmt.parseInt(u32, tok, 10) catch null);
    if (num) |nn| {
        if (idx == 4) {
            const d = if (nn == 7) 0 else nn;
            if (d <= 6) {
                out.appendSlice(a, sched.dow_title[d]) catch {};
                return;
            }
        } else if (idx == 3 and nn >= 1 and nn <= 12) {
            out.appendSlice(a, sched.month_title[nn - 1]) catch {};
            return;
        }
    }
    out.appendSlice(a, tok) catch {};
}

pub fn titleField(a: std.mem.Allocator, idx: usize, field: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, field, ',');
    var first = true;
    while (it.next()) |part| {
        if (!first) out.appendSlice(a, ", ") catch {};
        first = false;
        if (std.mem.indexOfScalar(u8, part, '-')) |dp| {
            appendName(a, &out, idx, part[0..dp]);
            out.appendSlice(a, "\xe2\x80\x93") catch {};
            appendName(a, &out, idx, part[dp + 1 ..]);
        } else appendName(a, &out, idx, part);
    }
    return out.toOwnedSlice(a) catch field;
}

pub fn humanize(a: std.mem.Allocator, raw_in: []const u8) []const u8 {
    const raw = std.mem.trim(u8, raw_in, " \t");
    if (raw.len > 0 and raw[0] == '@') {
        const m = raw[1..];
        if (std.ascii.eqlIgnoreCase(m, "reboot")) return "at boot";
        if (std.ascii.eqlIgnoreCase(m, "hourly")) return "every hour, on the hour";
        if (std.ascii.eqlIgnoreCase(m, "daily") or std.ascii.eqlIgnoreCase(m, "midnight")) return "every day at midnight";
        if (std.ascii.eqlIgnoreCase(m, "weekly")) return "every Sunday at midnight";
        if (std.ascii.eqlIgnoreCase(m, "monthly")) return "on the 1st of every month at midnight";
        if (std.ascii.eqlIgnoreCase(m, "yearly") or std.ascii.eqlIgnoreCase(m, "annually")) return "on Jan 1 at midnight";
        return raw;
    }
    var f: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |x| {
        if (n >= 5) break;
        f[n] = x;
        n += 1;
    }
    if (n != 5) return raw;
    const m = f[0];
    const h = f[1];
    const dom = f[2];
    const mon = f[3];
    const dow = f[4];
    var time_clause: []const u8 = "";
    if (std.mem.eql(u8, m, "*") and std.mem.eql(u8, h, "*")) {
        time_clause = "every minute";
    } else if (std.mem.startsWith(u8, m, "*/")) {
        // "every N minutes" composes with an hour constraint (single
        // value, range, or step) so the hour scope is not silently lost.
        const minute_part = std.fmt.allocPrint(a, "every {s} minutes", .{m[2..]}) catch raw;
        time_clause = if (std.mem.eql(u8, h, "*")) minute_part else if (std.mem.indexOfScalar(u8, h, '-') != null) (std.fmt.allocPrint(a, "{s} between hours {s}", .{ minute_part, h }) catch minute_part) else (std.fmt.allocPrint(a, "{s} at hour {s}", .{ minute_part, h }) catch minute_part);
    } else if (std.mem.eql(u8, h, "*")) {
        time_clause = std.fmt.allocPrint(a, "every hour at minute {s}", .{m}) catch raw;
    } else if (std.mem.startsWith(u8, h, "*/")) {
        time_clause = std.fmt.allocPrint(a, "every {s} hours at minute {s}", .{ h[2..], m }) catch raw;
    } else {
        const mi = std.fmt.parseInt(u32, m, 10) catch null;
        const hi = std.fmt.parseInt(u32, h, 10) catch null;
        time_clause = if (mi != null and hi != null) (std.fmt.allocPrint(a, "at {d:0>2}:{d:0>2}", .{ hi.?, mi.? }) catch raw) else (std.fmt.allocPrint(a, "at minute {s} of hour {s}", .{ m, h }) catch raw);
    }
    const dom_star = std.mem.eql(u8, dom, "*");
    const dow_star = std.mem.eql(u8, dow, "*");
    var day_clause: []const u8 = "";
    if (!dow_star and dom_star) day_clause = std.fmt.allocPrint(a, " on {s}", .{titleField(a, 4, dow)}) catch "" else if (dow_star and !dom_star) day_clause = std.fmt.allocPrint(a, " on day {s} of the month", .{dom}) catch "" else if (!dow_star and !dom_star) day_clause = std.fmt.allocPrint(a, " on {s} or day {s}", .{ titleField(a, 4, dow), dom }) catch "";
    var mon_clause: []const u8 = "";
    if (!std.mem.eql(u8, mon, "*")) mon_clause = std.fmt.allocPrint(a, " in {s}", .{titleField(a, 3, mon)}) catch "";
    if (day_clause.len == 0 and mon_clause.len == 0 and !std.mem.eql(u8, time_clause, "every minute")) day_clause = " every day";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ time_clause, day_clause, mon_clause }) catch raw;
}

pub fn relTime(a: std.mem.Allocator, delta_in: i64) []const u8 {
    var d = delta_in;
    const past = d < 0;
    if (past) d = -d;
    if (d < 60) return "now";
    const mins = @divTrunc(d, 60);
    const hours = @divTrunc(mins, 60);
    const days = @divTrunc(hours, 24);
    const core = if (days > 0) (std.fmt.allocPrint(a, "{d}d {d}h", .{ days, @mod(hours, 24) }) catch "") else if (hours > 0) (std.fmt.allocPrint(a, "{d}h {d}m", .{ hours, @mod(mins, 60) }) catch "") else (std.fmt.allocPrint(a, "{d}m", .{mins}) catch "");
    return std.fmt.allocPrint(a, "{s} {s}", .{ if (past) "" else "in", core }) catch core;
}

pub fn fmtWhen(a: std.mem.Allocator, ts: i64) []const u8 {
    const nr = @import("next_run.zig");
    const tm = nr.epochToTm(ts);
    const now = @import("../posix.zig").nowEpoch();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}  {s}", .{
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        relTime(a, ts - now),
    }) catch "";
}

/// Format a UTC epoch as a wall-clock string in the supplied zone, with
/// an unambiguous TZ tag. Computes the broken-down time by shifting the
/// epoch by `tz.offset_secs` and using `gmtime_r` — so the result is
/// always "wall clock in tz" regardless of the controller's `/etc/localtime`.
///
/// When `tz.source == .controller_fallback`, the string is suffixed with
/// "(controller-local)" so a reader can never mistake a fallback render
/// for the target's actual wall clock.
pub fn fmtWhenIn(a: std.mem.Allocator, ts: i64, tz: @import("../tz.zig").TzInfo) []const u8 {
    const posix = @import("../posix.zig");
    const c = posix.c;
    var shifted: c.time_t = @intCast(ts + tz.offset_secs);
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&shifted, &tm);
    const now = posix.nowEpoch();
    const base = std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {s}  {s}", .{
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        tz.abbrev,
        relTime(a, ts - now),
    }) catch "";
    if (tz.source == .controller_fallback) {
        return std.fmt.allocPrint(a, "{s} (controller-local)", .{base}) catch base;
    }
    return base;
}

const testing = std.testing;

test "humanize @reboot" {
    try testing.expectEqualStrings("at boot", humanize(std.testing.allocator, "@reboot"));
}

test "humanize @daily and @midnight equivalent" {
    try testing.expectEqualStrings("every day at midnight", humanize(std.testing.allocator, "@daily"));
    try testing.expectEqualStrings("every day at midnight", humanize(std.testing.allocator, "@midnight"));
}

test "humanize every-N-minutes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = humanize(arena.allocator(), "*/5 * * * *");
    try testing.expect(std.mem.indexOf(u8, out, "every 5 minutes") != null);
}

test "humanize fixed time formats as HH:MM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = humanize(arena.allocator(), "0 9 * * 1-5");
    try testing.expect(std.mem.indexOf(u8, out, "09:00") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Mon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Fri") != null);
}

test "humanize named months render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = humanize(arena.allocator(), "0 0 1 1 *");
    try testing.expect(std.mem.indexOf(u8, out, "Jan") != null);
}

test "relTime under one minute" {
    try testing.expectEqualStrings("now", relTime(std.testing.allocator, 30));
    try testing.expectEqualStrings("now", relTime(std.testing.allocator, -30));
}

test "relTime hours format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = relTime(arena.allocator(), 3 * 3600 + 30 * 60);
    try testing.expectEqualStrings("in 3h 30m", out);
}

test "humanize composes */N minutes with hour range and DOW (commit-3 fix)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = humanize(arena.allocator(), "*/15 9-17 * * 1-5");
    // The hour range and DOW must both survive the */15 branch.
    try testing.expect(std.mem.indexOf(u8, out, "every 15 minutes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "9-17") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Mon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Fri") != null);
}

test "humanize */N minutes with single hour value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = humanize(arena.allocator(), "*/5 9 * * *");
    try testing.expect(std.mem.indexOf(u8, out, "every 5 minutes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "at hour 9") != null);
}

test "fmtWhenIn renders wall clock in the supplied zone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tz_mod = @import("../tz.zig");
    // 2026-05-21 12:00:00 UTC, +08:00 (SGT) → 2026-05-21 20:00 SGT.
    const tz: tz_mod.TzInfo = .{ .offset_secs = 8 * 3600, .abbrev = "SGT", .source = .target_probed };
    const out = fmtWhenIn(arena.allocator(), 1_779_364_800, tz);
    try testing.expect(std.mem.indexOf(u8, out, "2026-05-21 20:00") != null);
    try testing.expect(std.mem.indexOf(u8, out, "SGT") != null);
    try testing.expect(std.mem.indexOf(u8, out, "controller-local") == null);
}

test "fmtWhenIn appends (controller-local) when source is fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tz_mod = @import("../tz.zig");
    const tz: tz_mod.TzInfo = .{ .offset_secs = 0, .abbrev = "UTC", .source = .controller_fallback };
    const out = fmtWhenIn(arena.allocator(), 1_779_364_800, tz);
    try testing.expect(std.mem.indexOf(u8, out, "controller-local") != null);
}

test "fmtWhenIn negative offset (UTC-05:00, EST) shifts backward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tz_mod = @import("../tz.zig");
    // 2026-05-21 12:00:00 UTC, -05:00 (EST) → 2026-05-21 07:00 EST.
    const tz: tz_mod.TzInfo = .{ .offset_secs = -5 * 3600, .abbrev = "EST", .source = .target_probed };
    const out = fmtWhenIn(arena.allocator(), 1_779_364_800, tz);
    try testing.expect(std.mem.indexOf(u8, out, "2026-05-21 07:00") != null);
    try testing.expect(std.mem.indexOf(u8, out, "EST") != null);
}
