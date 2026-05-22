//! English → standard cron expression. Always compiles to real cron,
//! validated, and stored as cron — the English layer is a front-end only.
//! Returns null when a phrase can't be confidently interpreted.
const std = @import("std");
const sched = @import("schedule.zig");

fn normSpace(a: std.mem.Allocator, s: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    var prev_space = true;
    for (s) |ch0| {
        const ch = std.ascii.toLower(ch0);
        if (ch == ' ' or ch == '\t' or ch == ',') {
            if (!prev_space) {
                b.append(a, ' ') catch {};
                prev_space = true;
            }
        } else {
            b.append(a, ch) catch {};
            prev_space = false;
        }
    }
    const out = b.toOwnedSlice(a) catch s;
    return std.mem.trimEnd(u8, out, " ");
}

fn dayNameLookup(w: []const u8) ?u32 {
    const T = struct { n: []const u8, v: u32 };
    const days = [_]T{
        .{ .n = "sunday", .v = 0 },    .{ .n = "monday", .v = 1 }, .{ .n = "tuesday", .v = 2 },
        .{ .n = "wednesday", .v = 3 }, .{ .n = "thursday", .v = 4 }, .{ .n = "friday", .v = 5 },
        .{ .n = "saturday", .v = 6 },  .{ .n = "sun", .v = 0 },     .{ .n = "mon", .v = 1 },
        .{ .n = "tue", .v = 2 },       .{ .n = "tues", .v = 2 },    .{ .n = "wed", .v = 3 },
        .{ .n = "weds", .v = 3 },      .{ .n = "thu", .v = 4 },     .{ .n = "thur", .v = 4 },
        .{ .n = "thurs", .v = 4 },     .{ .n = "fri", .v = 5 },     .{ .n = "sat", .v = 6 },
    };
    for (days) |d| if (std.mem.eql(u8, w, d.n)) return d.v;
    return null;
}

fn dayNameNum(w: []const u8) ?u32 {
    if (dayNameLookup(w)) |v| return v;
    if (w.len > 1 and w[w.len - 1] == 's') return dayNameLookup(w[0 .. w.len - 1]);
    return null;
}

fn ordinalNum(w: []const u8) ?u32 {
    inline for (.{ "st", "nd", "rd", "th" }) |suf| {
        if (std.mem.endsWith(u8, w, suf)) return std.fmt.parseInt(u32, w[0 .. w.len - 2], 10) catch null;
    }
    return null;
}

const Clock = struct { h: u32, m: u32, used: usize };
fn parseClock(words: []const []const u8, i: usize) ?Clock {
    if (i >= words.len) return null;
    var w = words[i];
    if (std.mem.eql(u8, w, "noon") or std.mem.eql(u8, w, "midday")) return .{ .h = 12, .m = 0, .used = 1 };
    if (std.mem.eql(u8, w, "midnight")) return .{ .h = 0, .m = 0, .used = 1 };
    var used: usize = 1;
    var ampm: u8 = 0;
    if (std.mem.endsWith(u8, w, "am")) {
        ampm = 1;
        w = w[0 .. w.len - 2];
    } else if (std.mem.endsWith(u8, w, "pm")) {
        ampm = 2;
        w = w[0 .. w.len - 2];
    }
    if (w.len == 0) return null;
    var hh: u32 = 0;
    var mm: u32 = 0;
    if (std.mem.indexOfScalar(u8, w, ':')) |cidx| {
        hh = std.fmt.parseInt(u32, w[0..cidx], 10) catch return null;
        mm = std.fmt.parseInt(u32, w[cidx + 1 ..], 10) catch return null;
    } else hh = std.fmt.parseInt(u32, w, 10) catch return null;
    if (ampm == 0 and i + 1 < words.len) {
        const nx = words[i + 1];
        if (std.mem.eql(u8, nx, "am")) {
            ampm = 1;
            used = 2;
        } else if (std.mem.eql(u8, nx, "pm")) {
            ampm = 2;
            used = 2;
        } else if (std.mem.eql(u8, nx, "oclock") or std.mem.eql(u8, nx, "o'clock")) used = 2;
    }
    if (ampm == 1) {
        if (hh == 12) hh = 0;
    } else if (ampm == 2) {
        if (hh != 12) hh += 12;
    }
    if (hh > 23 or mm > 59) return null;
    return .{ .h = hh, .m = mm, .used = used };
}

fn isNumber(w: []const u8) bool {
    if (w.len == 0) return false;
    for (w) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn addDow(a: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) void {
    const piece = std.fmt.allocPrint(a, "{d}", .{v}) catch return;
    setDow(a, buf, piece);
}

fn setDow(a: std.mem.Allocator, buf: *std.ArrayList(u8), piece: []const u8) void {
    if (buf.items.len > 0) buf.append(a, ',') catch {};
    buf.appendSlice(a, piece) catch {};
}

pub fn nlpToCron(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const text = normSpace(a, raw);
    if (text.len == 0) return null;

    if (std.mem.eql(u8, text, "hourly")) return "0 * * * *";
    if (std.mem.eql(u8, text, "daily") or std.mem.eql(u8, text, "everyday") or std.mem.eql(u8, text, "nightly")) return "0 0 * * *";
    if (std.mem.eql(u8, text, "weekly")) return "0 0 * * 0";
    if (std.mem.eql(u8, text, "monthly")) return "0 0 1 * *";
    if (std.mem.eql(u8, text, "yearly") or std.mem.eql(u8, text, "annually")) return "0 0 1 1 *";
    if (std.mem.indexOf(u8, text, "reboot") != null or std.mem.indexOf(u8, text, "startup") != null or
        std.mem.eql(u8, text, "at boot") or std.mem.eql(u8, text, "on boot")) return "@reboot";

    var words: std.ArrayList([]const u8) = .empty;
    var wit = std.mem.tokenizeScalar(u8, text, ' ');
    while (wit.next()) |w| words.append(a, w) catch {};
    const ws = words.items;

    var minute: ?u32 = null;
    var hour: ?u32 = null;
    var dom: []const u8 = "*";
    const mon: []const u8 = "*";
    var dow_buf: std.ArrayList(u8) = .empty;
    var every_min: ?u32 = null;
    var every_hr: ?u32 = null;
    var hr_lo: ?u32 = null;
    var hr_hi: ?u32 = null;
    var scope = false;
    var time_found = false;
    var monthly = false;
    var yearly = false;

    var i: usize = 0;
    while (i < ws.len) : (i += 1) {
        const w = ws[i];
        if (std.mem.eql(u8, w, "every") and i + 1 < ws.len) {
            const nx = ws[i + 1];
            if (std.mem.startsWith(u8, nx, "minute")) {
                every_min = 1;
            } else if (std.mem.startsWith(u8, nx, "hour")) {
                every_hr = 1;
            } else if (isNumber(nx) and i + 2 < ws.len) {
                const n = std.fmt.parseInt(u32, nx, 10) catch 0;
                const unit = ws[i + 2];
                if (n > 0 and std.mem.startsWith(u8, unit, "min")) every_min = n
                else if (n > 0 and (std.mem.startsWith(u8, unit, "hour") or std.mem.eql(u8, unit, "hr") or std.mem.eql(u8, unit, "hrs"))) every_hr = n;
            }
        }
        if (std.mem.startsWith(u8, w, "weekday") or std.mem.eql(u8, w, "weekdays")) {
            setDow(a, &dow_buf, "1-5");
            scope = true;
        }
        if (std.mem.startsWith(u8, w, "weekend")) {
            setDow(a, &dow_buf, "0,6");
            scope = true;
        }
        if (std.mem.eql(u8, w, "daily") or std.mem.eql(u8, w, "everyday") or std.mem.eql(u8, w, "nightly")) scope = true;
        if (dayNameNum(w)) |dv| {
            if (i + 2 < ws.len and (std.mem.eql(u8, ws[i + 1], "to") or std.mem.eql(u8, ws[i + 1], "through") or std.mem.eql(u8, ws[i + 1], "thru"))) {
                if (dayNameNum(ws[i + 2])) |dv2| {
                    setDow(a, &dow_buf, std.fmt.allocPrint(a, "{d}-{d}", .{ dv, dv2 }) catch "*");
                    scope = true;
                    i += 2;
                    continue;
                }
            }
            addDow(a, &dow_buf, dv);
            scope = true;
        }
        if (std.mem.eql(u8, w, "monthly")) {
            monthly = true;
            scope = true;
        }
        if (std.mem.eql(u8, w, "yearly") or std.mem.eql(u8, w, "annually")) {
            yearly = true;
            scope = true;
        }
        if (std.mem.eql(u8, w, "day") and i + 1 < ws.len and isNumber(ws[i + 1])) {
            dom = ws[i + 1];
            scope = true;
        }
        if (ordinalNum(w)) |on| {
            const prev: []const u8 = if (i > 0) ws[i - 1] else "";
            const day_ctx = std.mem.indexOf(u8, text, "month") != null or std.mem.indexOf(u8, text, " of ") != null or std.mem.eql(u8, prev, "the") or std.mem.eql(u8, prev, "on");
            if (on >= 1 and on <= 31 and day_ctx) {
                dom = std.fmt.allocPrint(a, "{d}", .{on}) catch "*";
                scope = true;
            }
        }
        if (std.mem.eql(u8, w, "from")) {
            if (parseClock(ws, i + 1)) |c1| {
                hr_lo = c1.h;
                var j = i + 1 + c1.used;
                if (j < ws.len and (std.mem.eql(u8, ws[j], "to") or std.mem.eql(u8, ws[j], "until") or std.mem.eql(u8, ws[j], "till"))) {
                    if (parseClock(ws, j + 1)) |c2| hr_hi = c2.h;
                }
                _ = &j;
            }
        }
        if (std.mem.eql(u8, w, "at")) {
            if (parseClock(ws, i + 1)) |ck| {
                hour = ck.h;
                minute = ck.m;
                time_found = true;
            }
        } else if (std.mem.eql(u8, w, "noon") or std.mem.eql(u8, w, "midday")) {
            hour = 12;
            minute = 0;
            time_found = true;
        } else if (std.mem.eql(u8, w, "midnight")) {
            hour = 0;
            minute = 0;
            time_found = true;
        } else if (!time_found and (std.mem.indexOfScalar(u8, w, ':') != null or std.mem.endsWith(u8, w, "am") or std.mem.endsWith(u8, w, "pm"))) {
            if (parseClock(ws, i)) |ck| {
                hour = ck.h;
                minute = ck.m;
                time_found = true;
            }
        }
    }

    const dow: []const u8 = if (dow_buf.items.len > 0) dow_buf.items else "*";

    if (every_min) |n| {
        const m: []const u8 = if (n == 1) "*" else std.fmt.allocPrint(a, "*/{d}", .{n}) catch "*";
        const h: []const u8 = if (hr_lo != null and hr_hi != null) (std.fmt.allocPrint(a, "{d}-{d}", .{ hr_lo.?, hr_hi.? }) catch "*") else "*";
        return std.fmt.allocPrint(a, "{s} {s} * * {s}", .{ m, h, dow }) catch null;
    }
    if (every_hr) |n| {
        const h: []const u8 = if (n == 1) "*" else std.fmt.allocPrint(a, "*/{d}", .{n}) catch "*";
        return std.fmt.allocPrint(a, "0 {s} * * {s}", .{ h, dow }) catch null;
    }
    if (!time_found and !scope) return null;
    const mm = minute orelse 0;
    const hh = hour orelse 0;
    if (yearly) return std.fmt.allocPrint(a, "{d} {d} 1 1 *", .{ mm, hh }) catch null;
    if (monthly and std.mem.eql(u8, dom, "*")) dom = "1";
    return std.fmt.allocPrint(a, "{d} {d} {s} {s} {s}", .{ mm, hh, dom, mon, dow }) catch null;
}

/// Resolve a user schedule arg: valid cron passes through; else try English.
pub fn toCron(a: std.mem.Allocator, input: []const u8) ?[]const u8 {
    _ = sched.parseSchedule(input) catch return nlpToCron(a, input);
    return input;
}
