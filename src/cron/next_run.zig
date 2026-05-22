//! Next-run computation. DST-correct via libc `localtime_r` / `mktime`.
//! Implements the Vixie DOM/DOW OR-rule: when both DOM and DOW are
//! constrained, a job fires when EITHER matches.
const std = @import("std");
const posix = @import("../posix.zig");
const c = posix.c;
const sched = @import("schedule.zig");
const Schedule = sched.Schedule;

pub fn epochToTm(secs: i64) c.struct_tm {
    var tt: c.time_t = @intCast(secs);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&tt, &tm);
    return tm;
}

pub fn tmToEpoch(tm: *c.struct_tm) i64 {
    return @intCast(c.mktime(tm));
}

pub fn nextRun(s: Schedule, from: i64) ?i64 {
    if (s.reboot) return null;
    var ts: i64 = from - @mod(from, 60) + 60;
    var guard: usize = 0;
    const max_iter: usize = 366 * 24 * 60 * 6;
    while (guard < max_iter) : (guard += 1) {
        var tm = epochToTm(ts);
        const mon: u32 = @intCast(tm.tm_mon + 1);
        if ((s.mon & (@as(u16, 1) << @intCast(mon))) == 0) {
            tm.tm_mon += 1;
            tm.tm_mday = 1;
            tm.tm_hour = 0;
            tm.tm_min = 0;
            tm.tm_sec = 0;
            ts = tmToEpoch(&tm);
            continue;
        }
        if (!s.matchesDay(@intCast(tm.tm_mday), @intCast(tm.tm_wday))) {
            tm.tm_mday += 1;
            tm.tm_hour = 0;
            tm.tm_min = 0;
            tm.tm_sec = 0;
            ts = tmToEpoch(&tm);
            continue;
        }
        if ((s.hour & (@as(u32, 1) << @intCast(tm.tm_hour))) == 0) {
            tm.tm_hour += 1;
            tm.tm_min = 0;
            tm.tm_sec = 0;
            ts = tmToEpoch(&tm);
            continue;
        }
        if ((s.min & (@as(u64, 1) << @intCast(tm.tm_min))) == 0) {
            tm.tm_min += 1;
            tm.tm_sec = 0;
            ts = tmToEpoch(&tm);
            continue;
        }
        return ts;
    }
    return null;
}

const testing = std.testing;

test "nextRun @reboot returns null" {
    const s = try sched.parseSchedule("@reboot");
    try testing.expectEqual(@as(?i64, null), nextRun(s, 0));
}

test "nextRun every-minute advances exactly 60s" {
    const s = try sched.parseSchedule("* * * * *");
    // Pick an epoch on the minute boundary to make the math obvious.
    const from: i64 = 1_700_000_000; // arbitrary fixed time
    const aligned = from - @mod(from, 60);
    const nr = nextRun(s, aligned).?;
    try testing.expectEqual(aligned + 60, nr);
}

test "nextRun zero-minute hourly advances at most 60 minutes" {
    const s = try sched.parseSchedule("0 * * * *");
    const from: i64 = 1_700_000_000;
    const nr = nextRun(s, from).?;
    const diff = nr - from;
    try testing.expect(diff > 0 and diff <= 60 * 60);
}

test "nextRun DOM/DOW OR-rule (cross-check via matchesDay)" {
    // Sanity: when both DOM and DOW are constrained, any next-run we get back
    // must satisfy at least one of them.
    const s = try sched.parseSchedule("0 0 13 * 5");
    const from: i64 = 1_700_000_000;
    const nr = nextRun(s, from).?;
    const tm = epochToTm(nr);
    const mday: u32 = @intCast(tm.tm_mday);
    const wday: u32 = @intCast(tm.tm_wday);
    try testing.expect(mday == 13 or wday == 5);
}

test "nextRun produces increasing sequence" {
    const s = try sched.parseSchedule("0 9 * * *");
    var from: i64 = 1_700_000_000;
    var last: i64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const nr = nextRun(s, from).?;
        try testing.expect(nr > last);
        last = nr;
        from = nr;
    }
}
