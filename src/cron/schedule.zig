//! Cron schedule bitmap + standard-5-field parser. Pure computation,
//! no I/O. Supports the @macros cron itself understands.
const std = @import("std");

pub const ParseError = error{ EmptyField, BadNumber, OutOfRange, BadRange, BadStep, BadMacro, WrongFieldCount };

pub const Schedule = struct {
    min: u64 = 0,
    hour: u32 = 0,
    dom: u32 = 0,
    mon: u16 = 0,
    dow: u8 = 0,
    dom_star: bool = false,
    dow_star: bool = false,
    reboot: bool = false,
    pub fn matchesDay(s: Schedule, mday: u32, wday: u32) bool {
        const dom_hit = (s.dom & (@as(u32, 1) << @intCast(mday))) != 0;
        const dow_hit = (s.dow & (@as(u8, 1) << @intCast(wday))) != 0;
        if (!s.dom_star and !s.dow_star) return dom_hit or dow_hit;
        if (!s.dom_star) return dom_hit;
        if (!s.dow_star) return dow_hit;
        return true;
    }
};

pub const Bounds = struct { lo: u32, hi: u32 };
pub fn fieldBounds(idx: usize) Bounds {
    return switch (idx) {
        0 => .{ .lo = 0, .hi = 59 },
        1 => .{ .lo = 0, .hi = 23 },
        2 => .{ .lo = 1, .hi = 31 },
        3 => .{ .lo = 1, .hi = 12 },
        4 => .{ .lo = 0, .hi = 7 },
        else => unreachable,
    };
}

pub const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
pub const dow_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
pub const month_title = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
pub const dow_title = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

pub fn nameToNum(idx: usize, tok: []const u8) ?u32 {
    if (idx == 3) {
        for (month_names, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m, tok)) return @intCast(i + 1);
    } else if (idx == 4) {
        for (dow_names, 0..) |d, i| if (std.ascii.eqlIgnoreCase(d, tok)) return @intCast(i);
    }
    return null;
}

pub fn parseNum(idx: usize, tok: []const u8) ParseError!u32 {
    if (nameToNum(idx, tok)) |n| return n;
    return std.fmt.parseInt(u32, tok, 10) catch return ParseError.BadNumber;
}

pub fn parseField(idx: usize, field: []const u8, star: *bool) ParseError!u64 {
    const b = fieldBounds(idx);
    if (field.len == 0) return ParseError.EmptyField;
    var mask: u64 = 0;
    var it = std.mem.splitScalar(u8, field, ',');
    while (it.next()) |part0| {
        if (part0.len == 0) return ParseError.EmptyField;
        var part = part0;
        var step: u32 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |sp| {
            step = std.fmt.parseInt(u32, part[sp + 1 ..], 10) catch return ParseError.BadStep;
            if (step == 0) return ParseError.BadStep;
            part = part[0..sp];
        }
        var lo: u32 = b.lo;
        var hi: u32 = b.hi;
        if (std.mem.eql(u8, part, "*")) {
            star.* = true;
        } else if (std.mem.indexOfScalar(u8, part, '-')) |dp| {
            lo = try parseNum(idx, part[0..dp]);
            hi = try parseNum(idx, part[dp + 1 ..]);
        } else {
            lo = try parseNum(idx, part);
            hi = if (step == 1) lo else b.hi;
        }
        if (lo < b.lo or hi > b.hi or lo > hi) return ParseError.OutOfRange;
        var v = lo;
        while (v <= hi) : (v += step) {
            var nv = v;
            if (idx == 4 and nv == 7) nv = 0;
            mask |= (@as(u64, 1) << @intCast(nv));
        }
    }
    return mask;
}

pub fn parseSchedule(expr_in: []const u8) ParseError!Schedule {
    const expr = std.mem.trim(u8, expr_in, " \t");
    if (expr.len == 0) return ParseError.WrongFieldCount;
    if (expr[0] == '@') {
        const m = expr[1..];
        if (std.ascii.eqlIgnoreCase(m, "reboot")) return .{ .reboot = true };
        const mapped: ?[]const u8 =
            if (std.ascii.eqlIgnoreCase(m, "yearly") or std.ascii.eqlIgnoreCase(m, "annually")) "0 0 1 1 *"
            else if (std.ascii.eqlIgnoreCase(m, "monthly")) "0 0 1 * *"
            else if (std.ascii.eqlIgnoreCase(m, "weekly")) "0 0 * * 0"
            else if (std.ascii.eqlIgnoreCase(m, "daily") or std.ascii.eqlIgnoreCase(m, "midnight")) "0 0 * * *"
            else if (std.ascii.eqlIgnoreCase(m, "hourly")) "0 * * * *"
            else null;
        if (mapped) |mm| return parseSchedule(mm);
        return ParseError.BadMacro;
    }
    var fields: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |f| {
        if (n >= 5) return ParseError.WrongFieldCount;
        fields[n] = f;
        n += 1;
    }
    if (n != 5) return ParseError.WrongFieldCount;
    var s = Schedule{};
    var dummy = false;
    s.min = try parseField(0, fields[0], &dummy);
    s.hour = @intCast(try parseField(1, fields[1], &dummy));
    s.dom = @intCast(try parseField(2, fields[2], &s.dom_star));
    s.mon = @intCast(try parseField(3, fields[3], &dummy));
    s.dow = @intCast(try parseField(4, fields[4], &s.dow_star));
    return s;
}
