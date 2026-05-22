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
