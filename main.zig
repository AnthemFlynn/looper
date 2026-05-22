//! looper — a sharp little tool that manages one-to-many cron jobs.
//! Do one thing well: manage cron jobs — locally, for another user, on a
//! remote host over ssh, or in a plain crontab file. It speaks standard
//! 5-field cron + the @macros cron itself understands; it never invents a
//! scheduler. Every mutation is backed up first: no `crontab -r` footgun.
//
// Build: zig build-exe main.zig -O ReleaseSafe -lc -femit-bin=looper
// Cross: zig build-exe main.zig -O ReleaseSafe -lc -target aarch64-macos -femit-bin=looper
const std = @import("std");
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h"); @cInclude("stdlib.h"); @cInclude("string.h");
    @cInclude("sys/wait.h"); @cInclude("sys/stat.h"); @cInclude("fcntl.h");
    @cInclude("dirent.h"); @cInclude("time.h");
});
const VERSION = "1.0.0";

const RESET="\x1b[0m"; const BOLD="\x1b[1m"; const DIM="\x1b[2m";
const RED="\x1b[31m"; const GREEN="\x1b[32m"; const YELLOW="\x1b[33m";
const BLUE="\x1b[34m"; const CYAN="\x1b[36m";

const Ctx = struct {
    a: std.mem.Allocator,
    color: bool = false, json: bool = false, dry_run: bool = false,
    yes: bool = false, quiet: bool = false,
    buf: std.ArrayList(u8) = .empty,
    fn emit(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.a, fmt, args) catch return;
        self.buf.appendSlice(self.a, s) catch {};
    }
    fn flush(self: *Ctx) void {
        if (self.buf.items.len == 0) return;
        _ = c.write(1, self.buf.items.ptr, self.buf.items.len);
        self.buf.clearRetainingCapacity();
    }
    fn k(self: *Ctx, code: []const u8) []const u8 { return if (self.color) code else ""; }
};
fn eprint(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = c.write(2, s.ptr, s.len);
}
fn aw(a: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(a, fmt, args) catch return;
    list.appendSlice(a, s) catch {};
}
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}
fn nowEpoch() i64 { return @intCast(c.time(null)); }
var g_exit: u8 = 0;
fn g_fail() void { if (g_exit == 0) g_exit = 1; }

// ---- process exec via POSIX (stable C ABI; sidesteps churning std.Io) ----
const RunResult = struct { code: i32, out: []u8 };
fn runCapture(a: std.mem.Allocator, argv: []const []const u8, stdin_bytes: ?[]const u8) !RunResult {
    var inpipe: [2]c_int = .{ -1, -1 };
    var outpipe: [2]c_int = undefined;
    if (c.pipe(&outpipe) != 0) return error.Pipe;
    if (stdin_bytes != null) if (c.pipe(&inpipe) != 0) return error.Pipe;
    const cargv = try a.alloc([*c]u8, argv.len + 1);
    for (argv, 0..) |arg, i| cargv[i] = (try a.dupeZ(u8, arg)).ptr;
    cargv[argv.len] = null;
    const pid = c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = c.dup2(outpipe[1], 1);
        _ = c.close(outpipe[0]); _ = c.close(outpipe[1]);
        if (stdin_bytes != null) { _ = c.dup2(inpipe[0], 0); _ = c.close(inpipe[0]); _ = c.close(inpipe[1]); }
        _ = c.execvp(cargv[0], cargv.ptr);
        c._exit(127);
    }
    _ = c.close(outpipe[1]);
    if (stdin_bytes) |b| { _ = c.close(inpipe[0]); if (b.len > 0) _ = c.write(inpipe[1], b.ptr, b.len); _ = c.close(inpipe[1]); }
    var out: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    while (true) { const n = c.read(outpipe[0], &tmp, tmp.len); if (n <= 0) break; try out.appendSlice(a, tmp[0..@intCast(n)]); }
    _ = c.close(outpipe[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const code: i32 = if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else -1;
    return .{ .code = code, .out = try out.toOwnedSlice(a) };
}
fn runInherit(a: std.mem.Allocator, argv: []const []const u8) !i32 {
    const cargv = try a.alloc([*c]u8, argv.len + 1);
    for (argv, 0..) |arg, i| cargv[i] = (try a.dupeZ(u8, arg)).ptr;
    cargv[argv.len] = null;
    const pid = c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) { _ = c.execvp(cargv[0], cargv.ptr); c._exit(127); }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else -1;
}

// =================== CRON ENGINE (unit-tested separately) ===================
const ParseError = error{ EmptyField, BadNumber, OutOfRange, BadRange, BadStep, BadMacro, WrongFieldCount };
const Schedule = struct {
    min: u64 = 0, hour: u32 = 0, dom: u32 = 0, mon: u16 = 0, dow: u8 = 0,
    dom_star: bool = false, dow_star: bool = false, reboot: bool = false,
    fn matchesDay(s: Schedule, mday: u32, wday: u32) bool {
        const dom_hit = (s.dom & (@as(u32,1) << @intCast(mday))) != 0;
        const dow_hit = (s.dow & (@as(u8,1) << @intCast(wday))) != 0;
        if (!s.dom_star and !s.dow_star) return dom_hit or dow_hit;
        if (!s.dom_star) return dom_hit;
        if (!s.dow_star) return dow_hit;
        return true;
    }
};
const Bounds = struct { lo: u32, hi: u32 };
fn fieldBounds(idx: usize) Bounds {
    return switch (idx) {
        0 => .{ .lo = 0, .hi = 59 }, 1 => .{ .lo = 0, .hi = 23 },
        2 => .{ .lo = 1, .hi = 31 }, 3 => .{ .lo = 1, .hi = 12 },
        4 => .{ .lo = 0, .hi = 7 }, else => unreachable,
    };
}
const month_names = [_][]const u8{ "jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec" };
const dow_names = [_][]const u8{ "sun","mon","tue","wed","thu","fri","sat" };
const month_title = [_][]const u8{ "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" };
const dow_title = [_][]const u8{ "Sun","Mon","Tue","Wed","Thu","Fri","Sat" };
fn nameToNum(idx: usize, tok: []const u8) ?u32 {
    if (idx == 3) { for (month_names, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m, tok)) return @intCast(i + 1); }
    else if (idx == 4) { for (dow_names, 0..) |d, i| if (std.ascii.eqlIgnoreCase(d, tok)) return @intCast(i); }
    return null;
}
fn parseNum(idx: usize, tok: []const u8) ParseError!u32 {
    if (nameToNum(idx, tok)) |n| return n;
    return std.fmt.parseInt(u32, tok, 10) catch return ParseError.BadNumber;
}
fn parseField(idx: usize, field: []const u8, star: *bool) ParseError!u64 {
    const b = fieldBounds(idx);
    if (field.len == 0) return ParseError.EmptyField;
    var mask: u64 = 0;
    var it = std.mem.splitScalar(u8, field, ',');
    while (it.next()) |part0| {
        if (part0.len == 0) return ParseError.EmptyField;
        var part = part0; var step: u32 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |sp| {
            step = std.fmt.parseInt(u32, part[sp+1..], 10) catch return ParseError.BadStep;
            if (step == 0) return ParseError.BadStep;
            part = part[0..sp];
        }
        var lo: u32 = b.lo; var hi: u32 = b.hi;
        if (std.mem.eql(u8, part, "*")) { star.* = true; }
        else if (std.mem.indexOfScalar(u8, part, '-')) |dp| { lo = try parseNum(idx, part[0..dp]); hi = try parseNum(idx, part[dp+1..]); }
        else { lo = try parseNum(idx, part); hi = if (step == 1) lo else b.hi; }
        if (lo < b.lo or hi > b.hi or lo > hi) return ParseError.OutOfRange;
        var v = lo;
        while (v <= hi) : (v += step) { var nv = v; if (idx == 4 and nv == 7) nv = 0; mask |= (@as(u64,1) << @intCast(nv)); }
    }
    return mask;
}
fn parseSchedule(expr_in: []const u8) ParseError!Schedule {
    const expr = std.mem.trim(u8, expr_in, " \t");
    if (expr.len == 0) return ParseError.WrongFieldCount;
    if (expr[0] == '@') {
        const m = expr[1..];
        if (std.ascii.eqlIgnoreCase(m, "reboot")) return .{ .reboot = true };
        const mapped: ?[]const u8 =
            if (std.ascii.eqlIgnoreCase(m,"yearly") or std.ascii.eqlIgnoreCase(m,"annually")) "0 0 1 1 *"
            else if (std.ascii.eqlIgnoreCase(m,"monthly")) "0 0 1 * *"
            else if (std.ascii.eqlIgnoreCase(m,"weekly")) "0 0 * * 0"
            else if (std.ascii.eqlIgnoreCase(m,"daily") or std.ascii.eqlIgnoreCase(m,"midnight")) "0 0 * * *"
            else if (std.ascii.eqlIgnoreCase(m,"hourly")) "0 * * * *" else null;
        if (mapped) |mm| return parseSchedule(mm);
        return ParseError.BadMacro;
    }
    var fields: [5][]const u8 = undefined; var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |f| { if (n >= 5) return ParseError.WrongFieldCount; fields[n] = f; n += 1; }
    if (n != 5) return ParseError.WrongFieldCount;
    var s = Schedule{}; var dummy = false;
    s.min = try parseField(0, fields[0], &dummy);
    s.hour = @intCast(try parseField(1, fields[1], &dummy));
    s.dom = @intCast(try parseField(2, fields[2], &s.dom_star));
    s.mon = @intCast(try parseField(3, fields[3], &dummy));
    s.dow = @intCast(try parseField(4, fields[4], &s.dow_star));
    return s;
}
fn epochToTm(secs: i64) c.struct_tm { var tt: c.time_t = @intCast(secs); var tm: c.struct_tm = undefined; _ = c.localtime_r(&tt, &tm); return tm; }
fn tmToEpoch(tm: *c.struct_tm) i64 { return @intCast(c.mktime(tm)); }
fn nextRun(s: Schedule, from: i64) ?i64 {
    if (s.reboot) return null;
    var ts: i64 = from - @mod(from, 60) + 60;
    var guard: usize = 0; const max_iter: usize = 366*24*60*6;
    while (guard < max_iter) : (guard += 1) {
        var tm = epochToTm(ts);
        const mon: u32 = @intCast(tm.tm_mon + 1);
        if ((s.mon & (@as(u16,1) << @intCast(mon))) == 0) { tm.tm_mon += 1; tm.tm_mday = 1; tm.tm_hour = 0; tm.tm_min = 0; tm.tm_sec = 0; ts = tmToEpoch(&tm); continue; }
        if (!s.matchesDay(@intCast(tm.tm_mday), @intCast(tm.tm_wday))) { tm.tm_mday += 1; tm.tm_hour = 0; tm.tm_min = 0; tm.tm_sec = 0; ts = tmToEpoch(&tm); continue; }
        if ((s.hour & (@as(u32,1) << @intCast(tm.tm_hour))) == 0) { tm.tm_hour += 1; tm.tm_min = 0; tm.tm_sec = 0; ts = tmToEpoch(&tm); continue; }
        if ((s.min & (@as(u64,1) << @intCast(tm.tm_min))) == 0) { tm.tm_min += 1; tm.tm_sec = 0; ts = tmToEpoch(&tm); continue; }
        return ts;
    }
    return null;
}
fn appendName(a: std.mem.Allocator, out: *std.ArrayList(u8), idx: usize, tok: []const u8) void {
    const num: ?u32 = nameToNum(idx, tok) orelse (std.fmt.parseInt(u32, tok, 10) catch null);
    if (num) |nn| {
        if (idx == 4) { const d = if (nn == 7) 0 else nn; if (d <= 6) { out.appendSlice(a, dow_title[d]) catch {}; return; } }
        else if (idx == 3 and nn >= 1 and nn <= 12) { out.appendSlice(a, month_title[nn-1]) catch {}; return; }
    }
    out.appendSlice(a, tok) catch {};
}
fn titleField(a: std.mem.Allocator, idx: usize, field: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty; var it = std.mem.splitScalar(u8, field, ','); var first = true;
    while (it.next()) |part| {
        if (!first) out.appendSlice(a, ", ") catch {}; first = false;
        if (std.mem.indexOfScalar(u8, part, '-')) |dp| { appendName(a, &out, idx, part[0..dp]); out.appendSlice(a, "\xe2\x80\x93") catch {}; appendName(a, &out, idx, part[dp+1..]); }
        else appendName(a, &out, idx, part);
    }
    return out.toOwnedSlice(a) catch field;
}
fn humanize(a: std.mem.Allocator, raw_in: []const u8) []const u8 {
    const raw = std.mem.trim(u8, raw_in, " \t");
    if (raw.len > 0 and raw[0] == '@') {
        const m = raw[1..];
        if (std.ascii.eqlIgnoreCase(m,"reboot")) return "at boot";
        if (std.ascii.eqlIgnoreCase(m,"hourly")) return "every hour, on the hour";
        if (std.ascii.eqlIgnoreCase(m,"daily") or std.ascii.eqlIgnoreCase(m,"midnight")) return "every day at midnight";
        if (std.ascii.eqlIgnoreCase(m,"weekly")) return "every Sunday at midnight";
        if (std.ascii.eqlIgnoreCase(m,"monthly")) return "on the 1st of every month at midnight";
        if (std.ascii.eqlIgnoreCase(m,"yearly") or std.ascii.eqlIgnoreCase(m,"annually")) return "on Jan 1 at midnight";
        return raw;
    }
    var f: [5][]const u8 = undefined; var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |x| { if (n >= 5) break; f[n] = x; n += 1; }
    if (n != 5) return raw;
    const m = f[0]; const h = f[1]; const dom = f[2]; const mon = f[3]; const dow = f[4];
    var time_clause: []const u8 = "";
    if (std.mem.eql(u8,m,"*") and std.mem.eql(u8,h,"*")) time_clause = "every minute"
    else if (std.mem.startsWith(u8,m,"*/") and std.mem.eql(u8,h,"*")) time_clause = std.fmt.allocPrint(a, "every {s} minutes", .{m[2..]}) catch raw
    else if (std.mem.eql(u8,h,"*")) time_clause = std.fmt.allocPrint(a, "every hour at minute {s}", .{m}) catch raw
    else if (std.mem.startsWith(u8,h,"*/")) time_clause = std.fmt.allocPrint(a, "every {s} hours at minute {s}", .{h[2..], m}) catch raw
    else {
        const mi = std.fmt.parseInt(u32, m, 10) catch null;
        const hi = std.fmt.parseInt(u32, h, 10) catch null;
        time_clause = if (mi != null and hi != null) (std.fmt.allocPrint(a, "at {d:0>2}:{d:0>2}", .{hi.?, mi.?}) catch raw)
            else (std.fmt.allocPrint(a, "at minute {s} of hour {s}", .{m, h}) catch raw);
    }
    const dom_star = std.mem.eql(u8,dom,"*"); const dow_star = std.mem.eql(u8,dow,"*");
    var day_clause: []const u8 = "";
    if (!dow_star and dom_star) day_clause = std.fmt.allocPrint(a, " on {s}", .{titleField(a,4,dow)}) catch ""
    else if (dow_star and !dom_star) day_clause = std.fmt.allocPrint(a, " on day {s} of the month", .{dom}) catch ""
    else if (!dow_star and !dom_star) day_clause = std.fmt.allocPrint(a, " on {s} or day {s}", .{titleField(a,4,dow), dom}) catch "";
    var mon_clause: []const u8 = "";
    if (!std.mem.eql(u8,mon,"*")) mon_clause = std.fmt.allocPrint(a, " in {s}", .{titleField(a,3,mon)}) catch "";
    if (day_clause.len == 0 and mon_clause.len == 0 and !std.mem.eql(u8, time_clause, "every minute")) day_clause = " every day";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{time_clause, day_clause, mon_clause}) catch raw;
}
fn relTime(a: std.mem.Allocator, delta_in: i64) []const u8 {
    var d = delta_in; const past = d < 0; if (past) d = -d;
    if (d < 60) return "now";
    const mins = @divTrunc(d, 60); const hours = @divTrunc(mins, 60); const days = @divTrunc(hours, 24);
    const core = if (days > 0) (std.fmt.allocPrint(a, "{d}d {d}h", .{days, @mod(hours,24)}) catch "")
        else if (hours > 0) (std.fmt.allocPrint(a, "{d}h {d}m", .{hours, @mod(mins,60)}) catch "")
        else (std.fmt.allocPrint(a, "{d}m", .{mins}) catch "");
    return std.fmt.allocPrint(a, "{s} {s}", .{ if (past) "" else "in", core }) catch core;
    // note: for past we prefix nothing; rare in this tool (next runs are future)
}
fn fmtWhen(a: std.mem.Allocator, ts: i64) []const u8 {
    const tm = epochToTm(ts); const now = nowEpoch();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}  {s}", .{
        @as(u32,@intCast(tm.tm_year + 1900)), @as(u32,@intCast(tm.tm_mon + 1)), @as(u32,@intCast(tm.tm_mday)), @as(u32,@intCast(tm.tm_hour)), @as(u32,@intCast(tm.tm_min)), relTime(a, ts - now),
    }) catch "";
}

// =================== NATURAL-LANGUAGE SCHEDULING ===================
// Compile a subset of English into a STANDARD cron expression. The result is
// always real cron (validated + stored as cron); English is only a front-end.
// Returns null when the phrase can't be confidently interpreted.
fn normSpace(a: std.mem.Allocator, s: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    var prev_space = true;
    for (s) |ch0| {
        const ch = std.ascii.toLower(ch0);
        if (ch == ' ' or ch == '\t' or ch == ',') {
            if (!prev_space) { b.append(a, ' ') catch {}; prev_space = true; }
        } else { b.append(a, ch) catch {}; prev_space = false; }
    }
    const out = b.toOwnedSlice(a) catch s;
    return std.mem.trimEnd(u8, out, " ");
}
fn dayNameLookup(w: []const u8) ?u32 {
    const T = struct { n: []const u8, v: u32 };
    const days = [_]T{
        .{ .n = "sunday", .v = 0 }, .{ .n = "monday", .v = 1 }, .{ .n = "tuesday", .v = 2 },
        .{ .n = "wednesday", .v = 3 }, .{ .n = "thursday", .v = 4 }, .{ .n = "friday", .v = 5 },
        .{ .n = "saturday", .v = 6 }, .{ .n = "sun", .v = 0 }, .{ .n = "mon", .v = 1 },
        .{ .n = "tue", .v = 2 }, .{ .n = "tues", .v = 2 }, .{ .n = "wed", .v = 3 }, .{ .n = "weds", .v = 3 },
        .{ .n = "thu", .v = 4 }, .{ .n = "thur", .v = 4 }, .{ .n = "thurs", .v = 4 },
        .{ .n = "fri", .v = 5 }, .{ .n = "sat", .v = 6 },
    };
    for (days) |d| if (std.mem.eql(u8, w, d.n)) return d.v;
    return null;
}
fn dayNameNum(w: []const u8) ?u32 {
    if (dayNameLookup(w)) |v| return v;
    if (w.len > 1 and w[w.len - 1] == 's') return dayNameLookup(w[0 .. w.len - 1]); // plural
    return null;
}
fn ordinalNum(w: []const u8) ?u32 {
    inline for (.{ "st", "nd", "rd", "th" }) |suf| {
        if (std.mem.endsWith(u8, w, suf)) return std.fmt.parseInt(u32, w[0 .. w.len - 2], 10) catch null;
    }
    return null; // not an ordinal (bare numbers are handled elsewhere)
}
const Clock = struct { h: u32, m: u32, used: usize };
fn parseClock(words: []const []const u8, i: usize) ?Clock {
    if (i >= words.len) return null;
    var w = words[i];
    if (std.mem.eql(u8, w, "noon") or std.mem.eql(u8, w, "midday")) return .{ .h = 12, .m = 0, .used = 1 };
    if (std.mem.eql(u8, w, "midnight")) return .{ .h = 0, .m = 0, .used = 1 };
    var used: usize = 1;
    var ampm: u8 = 0; // 1=am 2=pm
    if (std.mem.endsWith(u8, w, "am")) { ampm = 1; w = w[0 .. w.len - 2]; }
    else if (std.mem.endsWith(u8, w, "pm")) { ampm = 2; w = w[0 .. w.len - 2]; }
    if (w.len == 0) return null;
    var hh: u32 = 0; var mm: u32 = 0;
    if (std.mem.indexOfScalar(u8, w, ':')) |cidx| {
        hh = std.fmt.parseInt(u32, w[0..cidx], 10) catch return null;
        mm = std.fmt.parseInt(u32, w[cidx + 1 ..], 10) catch return null;
    } else hh = std.fmt.parseInt(u32, w, 10) catch return null;
    if (ampm == 0 and i + 1 < words.len) {
        const nx = words[i + 1];
        if (std.mem.eql(u8, nx, "am")) { ampm = 1; used = 2; }
        else if (std.mem.eql(u8, nx, "pm")) { ampm = 2; used = 2; }
        else if (std.mem.eql(u8, nx, "oclock") or std.mem.eql(u8, nx, "o'clock")) used = 2;
    }
    if (ampm == 1) { if (hh == 12) hh = 0; }
    else if (ampm == 2) { if (hh != 12) hh += 12; }
    if (hh > 23 or mm > 59) return null;
    return .{ .h = hh, .m = mm, .used = used };
}
fn isNumber(w: []const u8) bool {
    if (w.len == 0) return false;
    for (w) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}
fn nlpToCron(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const text = normSpace(a, raw);
    if (text.len == 0) return null;

    // single-word shorthands
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
    var dow_buf: std.ArrayList(u8) = .empty; // builds a dow list/range
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
        // intervals: "every [N] minute(s)|hour(s)"
        if (std.mem.eql(u8, w, "every") and i + 1 < ws.len) {
            const nx = ws[i + 1];
            if (std.mem.startsWith(u8, nx, "minute")) { every_min = 1; }
            else if (std.mem.startsWith(u8, nx, "hour")) { every_hr = 1; }
            else if (isNumber(nx) and i + 2 < ws.len) {
                const n = std.fmt.parseInt(u32, nx, 10) catch 0;
                const unit = ws[i + 2];
                if (n > 0 and std.mem.startsWith(u8, unit, "min")) every_min = n
                else if (n > 0 and (std.mem.startsWith(u8, unit, "hour") or std.mem.eql(u8, unit, "hr") or std.mem.eql(u8, unit, "hrs"))) every_hr = n;
            }
        }
        // weekday scopes
        if (std.mem.startsWith(u8, w, "weekday") or std.mem.eql(u8, w, "weekdays")) { setDow(a, &dow_buf, "1-5"); scope = true; }
        if (std.mem.startsWith(u8, w, "weekend")) { setDow(a, &dow_buf, "0,6"); scope = true; }
        if (std.mem.eql(u8, w, "daily") or std.mem.eql(u8, w, "everyday") or std.mem.eql(u8, w, "nightly")) scope = true;
        // day name, possibly "<day> to/through <day>" range
        if (dayNameNum(w)) |dv| {
            if (i + 2 < ws.len and (std.mem.eql(u8, ws[i + 1], "to") or std.mem.eql(u8, ws[i + 1], "through") or std.mem.eql(u8, ws[i + 1], "thru"))) {
                if (dayNameNum(ws[i + 2])) |dv2| { setDow(a, &dow_buf, std.fmt.allocPrint(a, "{d}-{d}", .{ dv, dv2 }) catch "*"); scope = true; i += 2; continue; }
            }
            addDow(a, &dow_buf, dv);
            scope = true;
        }
        // monthly / day-of-month
        if (std.mem.eql(u8, w, "monthly")) { monthly = true; scope = true; }
        if (std.mem.eql(u8, w, "yearly") or std.mem.eql(u8, w, "annually")) { yearly = true; scope = true; }
        if (std.mem.eql(u8, w, "day") and i + 1 < ws.len and isNumber(ws[i + 1])) {
            dom = ws[i + 1]; scope = true;
        }
        if (ordinalNum(w)) |on| {
            const prev: []const u8 = if (i > 0) ws[i - 1] else "";
            const day_ctx = std.mem.indexOf(u8, text, "month") != null or std.mem.indexOf(u8, text, " of ") != null or std.mem.eql(u8, prev, "the") or std.mem.eql(u8, prev, "on");
            if (on >= 1 and on <= 31 and day_ctx) { dom = std.fmt.allocPrint(a, "{d}", .{on}) catch "*"; scope = true; }
        }
        // "from <time> to <time>"  (hour window for intervals)
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
        // explicit time: "at <time>", or noon/midnight, or token with ':'/am/pm
        if (std.mem.eql(u8, w, "at")) {
            if (parseClock(ws, i + 1)) |ck| { hour = ck.h; minute = ck.m; time_found = true; }
        } else if (std.mem.eql(u8, w, "noon") or std.mem.eql(u8, w, "midday")) { hour = 12; minute = 0; time_found = true; }
        else if (std.mem.eql(u8, w, "midnight")) { hour = 0; minute = 0; time_found = true; }
        else if (!time_found and (std.mem.indexOfScalar(u8, w, ':') != null or std.mem.endsWith(u8, w, "am") or std.mem.endsWith(u8, w, "pm"))) {
            if (parseClock(ws, i)) |ck| { hour = ck.h; minute = ck.m; time_found = true; }
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
    if (!time_found and !scope) return null; // nothing recognized
    const mm = minute orelse 0;
    const hh = hour orelse 0;
    if (yearly) return std.fmt.allocPrint(a, "{d} {d} 1 1 *", .{ mm, hh }) catch null;
    if (monthly and std.mem.eql(u8, dom, "*")) dom = "1";
    return std.fmt.allocPrint(a, "{d} {d} {s} {s} {s}", .{ mm, hh, dom, mon, dow }) catch null;
}
fn addDow(a: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) void {
    const piece = std.fmt.allocPrint(a, "{d}", .{v}) catch return;
    setDow(a, buf, piece);
}
fn setDow(a: std.mem.Allocator, buf: *std.ArrayList(u8), piece: []const u8) void {
    if (buf.items.len > 0) buf.append(a, ',') catch {};
    buf.appendSlice(a, piece) catch {};
}
// Resolve a user schedule arg: valid cron passes through; else try English.
fn toCron(a: std.mem.Allocator, input: []const u8) ?[]const u8 {
    _ = parseSchedule(input) catch return nlpToCron(a, input);
    return input;
}

// =================== CRONTAB MODEL ===================
const MARKER = "#looper#";
const Job = struct { id: []const u8, enabled: bool, schedule: []const u8, command: []const u8, foreign: bool = false };
const Item = union(enum) { raw: []const u8, job: Job };
const Crontab = struct {
    items: std.ArrayList(Item) = .empty,
    fn findIndex(self: *const Crontab, id: []const u8) ?usize {
        for (self.items.items, 0..) |it, i| switch (it) {
            .job => |j| if (!j.foreign and std.mem.eql(u8, j.id, id)) return i,
            else => {},
        };
        return null;
    }
    /// item index of the nth (1-based) unmanaged job, as listed by `ls`
    fn findForeign(self: *const Crontab, n: usize) ?usize {
        var k: usize = 0;
        for (self.items.items, 0..) |it, i| switch (it) {
            .job => |j| if (j.foreign) { k += 1; if (k == n) return i; },
            else => {},
        };
        return null;
    }
};
fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}
const SC = struct { sched: []const u8, cmd: []const u8 };
fn splitScheduleCommand(line_in: []const u8) ?SC {
    const line = std.mem.trim(u8, line_in, " \t");
    if (line.len == 0) return null;
    if (line[0] == '@') {
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse return null;
        return .{ .sched = line[0..sp], .cmd = std.mem.trimStart(u8, line[sp..], " \t") };
    }
    var idx: usize = 0; var fc: usize = 0; var in_field = false; var fifth_end: usize = 0;
    while (idx < line.len) : (idx += 1) {
        const ws = line[idx] == ' ' or line[idx] == '\t';
        if (!ws and !in_field) { in_field = true; fc += 1; }
        else if (ws and in_field) { in_field = false; if (fc == 5) { fifth_end = idx; break; } }
    }
    if (fc < 5 or fifth_end == 0) return null;
    return .{ .sched = line[0..fifth_end], .cmd = std.mem.trimStart(u8, line[fifth_end..], " \t") };
}
fn isEnvAssignment(line: []const u8) bool {
    if (line.len == 0) return false;
    if (!(std.ascii.isAlphabetic(line[0]) or line[0] == '_')) return false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '=') return i > 0;
        if (ch == ' ' or ch == '\t') return false;
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return false;
}
const Marker = struct { id: []const u8, enabled: bool };
fn parseMarker(a: std.mem.Allocator, line: []const u8) ?Marker {
    if (!std.mem.startsWith(u8, line, MARKER)) return null;
    var id: []const u8 = ""; var enabled = true;
    var it = std.mem.tokenizeAny(u8, line[MARKER.len..], " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "id=")) id = a.dupe(u8, tok[3..]) catch tok[3..];
        if (std.mem.startsWith(u8, tok, "enabled=")) enabled = std.mem.eql(u8, tok[8..], "1");
    }
    if (id.len == 0) return null;
    return .{ .id = id, .enabled = enabled };
}
fn parseCrontab(a: std.mem.Allocator, text: []const u8) !Crontab {
    var ct = Crontab{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var pending: ?Marker = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (pending) |pm| {
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            var payload = line;
            if (!pm.enabled) { const t = std.mem.trimStart(u8, line, " \t"); if (std.mem.startsWith(u8, t, "#")) payload = std.mem.trimStart(u8, t[1..], " \t"); }
            if (splitScheduleCommand(payload)) |sc| {
                try ct.items.append(a, .{ .job = .{ .id = pm.id, .enabled = pm.enabled, .schedule = try a.dupe(u8, sc.sched), .command = try a.dupe(u8, sc.cmd) } });
            } else {
                try ct.items.append(a, .{ .raw = try std.fmt.allocPrint(a, "{s} id={s} enabled={d}", .{ MARKER, pm.id, @as(u8, if (pm.enabled) 1 else 0) }) });
                try ct.items.append(a, .{ .raw = try a.dupe(u8, line) });
            }
            pending = null;
            continue;
        }
        if (parseMarker(a, line)) |mk| { pending = mk; continue; }
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] != '#' and !isEnvAssignment(trimmed)) {
            if (splitScheduleCommand(line)) |sc| {
                try ct.items.append(a, .{ .job = .{ .id = "-", .enabled = true, .schedule = try a.dupe(u8, sc.sched), .command = try a.dupe(u8, sc.cmd), .foreign = true } });
                continue;
            }
        }
        try ct.items.append(a, .{ .raw = try a.dupe(u8, line) });
    }
    if (pending) |pm| try ct.items.append(a, .{ .raw = try std.fmt.allocPrint(a, "{s} id={s} enabled={d}", .{ MARKER, pm.id, @as(u8, if (pm.enabled) 1 else 0) }) });
    if (ct.items.items.len > 0) { const last = ct.items.items[ct.items.items.len - 1]; if (last == .raw and last.raw.len == 0) _ = ct.items.pop(); }
    return ct;
}
fn serialize(a: std.mem.Allocator, ct: *Crontab) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ct.items.items) |it| switch (it) {
        .raw => |r| { try out.appendSlice(a, r); try out.append(a, '\n'); },
        .job => |j| {
            if (j.foreign) { aw(a, &out, "{s} {s}\n", .{ j.schedule, j.command }); }
            else {
                aw(a, &out, "{s} id={s} enabled={d}\n", .{ MARKER, j.id, @as(u8, if (j.enabled) 1 else 0) });
                if (j.enabled) aw(a, &out, "{s} {s}\n", .{ j.schedule, j.command })
                else aw(a, &out, "# {s} {s}\n", .{ j.schedule, j.command });
            }
        },
    };
    return out.toOwnedSlice(a);
}

// =================== BACKENDS ===================
const TargetKind = enum { local, remote, file };
const Target = struct {
    kind: TargetKind, host: []const u8 = "", user: []const u8 = "", path: []const u8 = "",
    fn label(self: Target, a: std.mem.Allocator) []const u8 {
        return switch (self.kind) {
            .local => if (self.user.len > 0) (std.fmt.allocPrint(a, "local (user {s})", .{self.user}) catch "local") else "local",
            .remote => if (self.user.len > 0) (std.fmt.allocPrint(a, "{s} (user {s})", .{self.host, self.user}) catch self.host) else self.host,
            .file => std.fmt.allocPrint(a, "file:{s}", .{self.path}) catch "file",
        };
    }
    fn slug(self: Target, a: std.mem.Allocator) []const u8 {
        const raw = switch (self.kind) { .local => "local", .remote => self.host, .file => self.path };
        var b: std.ArrayList(u8) = .empty;
        for (raw) |ch| b.append(a, if (std.ascii.isAlphanumeric(ch) or ch=='-' or ch=='_' or ch=='.') ch else '_') catch {};
        if (self.user.len > 0) { b.appendSlice(a, "__") catch {}; for (self.user) |ch| b.append(a, if (std.ascii.isAlphanumeric(ch)) ch else '_') catch {}; }
        return b.toOwnedSlice(a) catch raw;
    }
};
const BackendError = error{ Unavailable, WriteFailed };
fn readFileAll(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try a.dupeZ(u8, path);
    const fd = c.open(pz.ptr, c.O_RDONLY);
    if (fd < 0) return "";
    defer _ = c.close(fd);
    var out: std.ArrayList(u8) = .empty; var tmp: [8192]u8 = undefined;
    while (true) { const n = c.read(fd, &tmp, tmp.len); if (n <= 0) break; try out.appendSlice(a, tmp[0..@intCast(n)]); }
    return out.toOwnedSlice(a);
}
fn writeFileAll(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const pz = try a.dupeZ(u8, path);
    const fd = c.open(pz.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return BackendError.WriteFailed;
    defer _ = c.close(fd);
    if (data.len > 0) { if (c.write(fd, data.ptr, data.len) < 0) return BackendError.WriteFailed; }
}
fn readCrontab(a: std.mem.Allocator, t: Target) ![]u8 {
    switch (t.kind) {
        .file => return readFileAll(a, t.path),
        .local => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, "crontab");
            if (t.user.len > 0) { try argv.append(a, "-u"); try argv.append(a, t.user); }
            try argv.append(a, "-l");
            const r = try runCapture(a, argv.items, null);
            if (r.code == 127) return BackendError.Unavailable;
            return r.out;
        },
        .remote => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, "ssh"); try argv.append(a, "-o"); try argv.append(a, "BatchMode=yes"); try argv.append(a, t.host); try argv.append(a, "crontab");
            if (t.user.len > 0) { try argv.append(a, "-u"); try argv.append(a, t.user); }
            try argv.append(a, "-l");
            const r = try runCapture(a, argv.items, null);
            if (r.code == 255 or r.code == 127) return BackendError.Unavailable;
            return r.out;
        },
    }
}
fn writeCrontab(a: std.mem.Allocator, t: Target, data: []const u8) !void {
    switch (t.kind) {
        .file => return writeFileAll(a, t.path, data),
        .local => {
            const tmpl = try a.dupeZ(u8, "/tmp/looper.XXXXXX");
            const fd = c.mkstemp(tmpl.ptr);
            if (fd < 0) return BackendError.WriteFailed;
            if (data.len > 0) _ = c.write(fd, data.ptr, data.len);
            _ = c.close(fd);
            const path = std.mem.span(tmpl.ptr);
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, "crontab");
            if (t.user.len > 0) { try argv.append(a, "-u"); try argv.append(a, t.user); }
            try argv.append(a, path);
            const r = try runCapture(a, argv.items, null);
            _ = c.unlink(tmpl.ptr);
            if (r.code != 0) return BackendError.WriteFailed;
        },
        .remote => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(a, "ssh"); try argv.append(a, "-o"); try argv.append(a, "BatchMode=yes"); try argv.append(a, t.host); try argv.append(a, "crontab");
            if (t.user.len > 0) { try argv.append(a, "-u"); try argv.append(a, t.user); }
            try argv.append(a, "-");
            const r = try runCapture(a, argv.items, data);
            if (r.code != 0) return BackendError.WriteFailed;
        },
    }
}
fn mkdirP(a: std.mem.Allocator, path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) if (i == path.len or path[i] == '/') {
        const seg = a.dupeZ(u8, path[0..i]) catch return; _ = c.mkdir(seg.ptr, 0o755);
    };
}
fn stateDir(a: std.mem.Allocator) []const u8 {
    if (getenv("XDG_STATE_HOME")) |x| return std.fmt.allocPrint(a, "{s}/looper", .{x}) catch ".";
    return std.fmt.allocPrint(a, "{s}/.local/state/looper", .{getenv("HOME") orelse "."}) catch ".";
}
fn utcStamp(a: std.mem.Allocator) []const u8 {
    var tt: c.time_t = @intCast(nowEpoch()); var tm: c.struct_tm = undefined; _ = c.gmtime_r(&tt, &tm);
    return std.fmt.allocPrint(a, "{d}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ @as(u32,@intCast(tm.tm_year+1900)), @as(u32,@intCast(tm.tm_mon+1)), @as(u32,@intCast(tm.tm_mday)), @as(u32,@intCast(tm.tm_hour)), @as(u32,@intCast(tm.tm_min)), @as(u32,@intCast(tm.tm_sec)) }) catch "stamp";
}
fn backupDir(a: std.mem.Allocator, t: Target) []const u8 { return std.fmt.allocPrint(a, "{s}/backups/{s}", .{ stateDir(a), t.slug(a) }) catch "."; }
fn doBackup(a: std.mem.Allocator, t: Target, content: []const u8) ?[]const u8 {
    const dir = backupDir(a, t); mkdirP(a, dir);
    const path = std.fmt.allocPrint(a, "{s}/{s}.crontab", .{ dir, utcStamp(a) }) catch return null;
    writeFileAll(a, path, content) catch return null;
    return path;
}
fn newestBackup(a: std.mem.Allocator, t: Target) ?[]const u8 {
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
fn confirm(ctx: *Ctx, comptime fmt: []const u8, args: anytype) bool {
    if (ctx.yes) return true;
    if (c.isatty(0) == 0) { eprint("looper: refusing without a tty; pass --yes\n", .{}); return false; }
    eprint(fmt ++ " [y/N] ", args);
    var b: [16]u8 = undefined; const n = c.read(0, &b, b.len);
    if (n <= 0) return false;
    return b[0] == 'y' or b[0] == 'Y';
}

// =================== DISPLAY HELPERS ===================
fn termWidth() usize {
    if (getenv("COLUMNS")) |cols| { if (std.fmt.parseInt(usize, cols, 10) catch null) |w| return w; }
    return 100;
}
fn padTo(a: std.mem.Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len >= w) return s;
    var b: std.ArrayList(u8) = .empty; b.appendSlice(a, s) catch return s;
    var i: usize = s.len; while (i < w) : (i += 1) b.append(a, ' ') catch {};
    return b.toOwnedSlice(a) catch s;
}
fn truncEllipsis(a: std.mem.Allocator, s: []const u8, w: usize) []const u8 {
    if (s.len <= w or w <= 1) return s;
    return std.fmt.allocPrint(a, "{s}\xe2\x80\xa6", .{s[0..w-1]}) catch s;
}
fn jsonEsc(a: std.mem.Allocator, s: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '"' => b.appendSlice(a, "\\\"") catch {},
        '\\' => b.appendSlice(a, "\\\\") catch {},
        '\n' => b.appendSlice(a, "\\n") catch {},
        '\t' => b.appendSlice(a, "\\t") catch {},
        else => b.append(a, ch) catch {},
    };
    return b.toOwnedSlice(a) catch s;
}
fn slugFromCommand(a: std.mem.Allocator, cmd: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, cmd, " \t"); var base = it.next() orelse "job";
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |p| base = base[p+1..];
    var b: std.ArrayList(u8) = .empty;
    for (base) |ch| if (std.ascii.isAlphanumeric(ch) or ch=='-' or ch=='_') b.append(a, std.ascii.toLower(ch)) catch {};
    if (b.items.len == 0) return "job";
    return b.toOwnedSlice(a) catch "job";
}
fn slugUnique(a: std.mem.Allocator, ct: *Crontab, cmd: []const u8) []const u8 {
    const base = slugFromCommand(a, cmd); var cand = base; var n: usize = 2;
    while (ct.findIndex(cand) != null) : (n += 1) cand = std.fmt.allocPrint(a, "{s}-{d}", .{ base, n }) catch base;
    return cand;
}

// =================== DIFF (for --dry-run) ===================
fn printDiff(ctx: *Ctx, old: []const u8, new: []const u8) void {
    const a = ctx.a;
    var ol: std.ArrayList([]const u8) = .empty; var nl: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, old, '\n'); while (it.next()) |l| ol.append(a, l) catch {};
    var it2 = std.mem.splitScalar(u8, new, '\n'); while (it2.next()) |l| nl.append(a, l) catch {};
    const m = ol.items.len; const n = nl.items.len;
    const dp = a.alloc(usize, (m+1)*(n+1)) catch return;
    for (dp) |*x| x.* = 0;
    var i: usize = m;
    while (i > 0) : (i -= 1) { var j: usize = n; while (j > 0) : (j -= 1) {
        const idx = (i-1)*(n+1)+(j-1);
        if (std.mem.eql(u8, ol.items[i-1], nl.items[j-1])) dp[idx] = dp[i*(n+1)+j] + 1
        else dp[idx] = @max(dp[i*(n+1)+(j-1)], dp[(i-1)*(n+1)+j]);
    } }
    var x: usize = 0; var y: usize = 0;
    while (x < m and y < n) {
        if (std.mem.eql(u8, ol.items[x], nl.items[y])) { ctx.emit("  {s}\n", .{ol.items[x]}); x += 1; y += 1; }
        else if (dp[(x+1)*(n+1)+y] >= dp[x*(n+1)+(y+1)]) { ctx.emit("{s}- {s}{s}\n", .{ctx.k(RED), ol.items[x], ctx.k(RESET)}); x += 1; }
        else { ctx.emit("{s}+ {s}{s}\n", .{ctx.k(GREEN), nl.items[y], ctx.k(RESET)}); y += 1; }
    }
    while (x < m) : (x += 1) ctx.emit("{s}- {s}{s}\n", .{ctx.k(RED), ol.items[x], ctx.k(RESET)});
    while (y < n) : (y += 1) ctx.emit("{s}+ {s}{s}\n", .{ctx.k(GREEN), nl.items[y], ctx.k(RESET)});
}

// =================== MUTATION + COMMANDS ===================
fn applyMutation(ctx: *Ctx, t: Target, content: []const u8, new_content: []const u8, verb: []const u8) !void {
    if (std.mem.eql(u8, content, new_content)) {
        if (!ctx.quiet) ctx.emit("{s}no change{s} on {s}\n", .{ctx.k(DIM), ctx.k(RESET), t.label(ctx.a)});
        return;
    }
    if (ctx.dry_run) {
        ctx.emit("{s}# dry-run: {s} on {s} (nothing written){s}\n", .{ctx.k(YELLOW), verb, t.label(ctx.a), ctx.k(RESET)});
        printDiff(ctx, content, new_content);
        return;
    }
    const bpath = doBackup(ctx.a, t, content);
    writeCrontab(ctx.a, t, new_content) catch |e| { eprint("looper: write failed on {s}: {s}\n", .{t.label(ctx.a), @errorName(e)}); g_fail(); return; };
    if (!ctx.quiet) {
        ctx.emit("{s}\xe2\x9c\x93{s} {s} on {s}", .{ctx.k(GREEN), ctx.k(RESET), verb, t.label(ctx.a)});
        if (bpath) |bp| ctx.emit("{s}  (backup: {s}){s}", .{ctx.k(DIM), bp, ctx.k(RESET)});
        ctx.emit("\n", .{});
    }
}
fn cmdLs(ctx: *Ctx, t: Target, content: []const u8) !void {
    const ct = try parseCrontab(ctx.a, content);
    const now = nowEpoch();
    if (ctx.json) {
        ctx.emit("[", .{}); var first = true;
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                if (!first) ctx.emit(",", .{}); first = false;
                const nr = nextRun(parseSchedule(j.schedule) catch Schedule{}, now);
                ctx.emit("{{\"id\":\"{s}\",\"enabled\":{s},\"foreign\":{s},\"schedule\":\"{s}\",\"command\":\"{s}\",\"next\":{d}}}", .{
                    j.id, if (j.enabled) "true" else "false", if (j.foreign) "true" else "false", jsonEsc(ctx.a, j.schedule), jsonEsc(ctx.a, j.command), nr orelse 0 });
            }, else => {},
        };
        ctx.emit("]\n", .{});
        return;
    }
    var managed: usize = 0; var foreign: usize = 0;
    for (ct.items.items) |it| switch (it) { .job => |j| { if (j.foreign) foreign += 1 else managed += 1; }, else => {} };
    if (managed == 0 and foreign == 0) { ctx.emit("{s}no cron jobs on {s}{s}\n", .{ctx.k(DIM), t.label(ctx.a), ctx.k(RESET)}); return; }
    const w = termWidth(); const cmd_w = if (w > 60) w - 56 else 24;
    ctx.emit("{s}{s}{s}{s}   {s}{s}\n", .{ ctx.k(BOLD), padTo(ctx.a, "ID", 14), padTo(ctx.a, "SCHEDULE", 22), padTo(ctx.a, "NEXT RUN", 24), "COMMAND", ctx.k(RESET) });
    var fcount: usize = 0;
    for (ct.items.items) |it| switch (it) {
        .job => |j| {
            const sched = parseSchedule(j.schedule) catch null;
            const nr: []const u8 = if (sched) |s| (if (nextRun(s, now)) |xx| fmtWhen(ctx.a, xx) else (if (s.reboot) "at boot" else "—")) else "INVALID";
            const idcol = if (j.foreign) blk: { fcount += 1; break :blk std.fmt.allocPrint(ctx.a, "f{d}", .{fcount}) catch "f?"; } else j.id;
            const idcolor = if (j.foreign) ctx.k(YELLOW) else ctx.k(CYAN);
            const dotcolor = if (j.foreign) ctx.k(YELLOW) else if (j.enabled) ctx.k(GREEN) else ctx.k(DIM);
            const dot = if (j.foreign) "?" else if (j.enabled) "\xe2\x97\x8f" else "\xe2\x97\x8b";
            ctx.emit("{s}{s}{s}{s}{s}{s}{s} {s}{s}{s} {s}\n", .{
                idcolor, padTo(ctx.a, idcol, 14), ctx.k(RESET),
                ctx.k(DIM), padTo(ctx.a, j.schedule, 22), ctx.k(RESET),
                padTo(ctx.a, nr, 24),
                dotcolor, dot, ctx.k(RESET),
                truncEllipsis(ctx.a, j.command, cmd_w),
            });
        }, else => {},
    };
    if (foreign > 0) ctx.emit("{s}\n{d} unmanaged job(s) shown as f1..f{d} — remove with 'looper rm f1', or adopt with 'looper import'{s}\n", .{ ctx.k(DIM), foreign, foreign, ctx.k(RESET) });
}
fn cmdAdd(ctx: *Ctx, t: Target, content: []const u8, schedule: []const u8, command: []const u8, want_id: ?[]const u8) !void {
    const cron = toCron(ctx.a, schedule) orelse {
        eprint("looper: couldn't read schedule '{s}'\n", .{schedule});
        eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        eprint("  preview with: looper explain '{s}'\n", .{schedule});
        g_fail();
        return;
    };
    _ = parseSchedule(cron) catch |e| {
        eprint("looper: invalid schedule '{s}': {s}\n", .{cron, @errorName(e)});
        g_fail();
        return;
    };
    if (!std.mem.eql(u8, cron, schedule))
        ctx.emit("{s}interpreted{s} \"{s}\" as {s}{s}{s}  ({s})\n", .{ ctx.k(DIM), ctx.k(RESET), schedule, ctx.k(BOLD), cron, ctx.k(RESET), humanize(ctx.a, cron) });
    var ct = try parseCrontab(ctx.a, content);
    const id = want_id orelse blk: {
        for (ct.items.items) |it| switch (it) { .job => |j| if (!j.foreign and std.mem.eql(u8, j.schedule, cron) and std.mem.eql(u8, j.command, command)) break :blk j.id, else => {} };
        break :blk slugUnique(ctx.a, &ct, command);
    };
    if (ct.findIndex(id)) |i| {
        ct.items.items[i].job.schedule = cron;
        ct.items.items[i].job.command = command;
        ct.items.items[i].job.enabled = true;
    } else try ct.items.append(ctx.a, .{ .job = .{ .id = id, .enabled = true, .schedule = cron, .command = command } });
    const new_content = try serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "set job '{s}'", .{id});
    try applyMutation(ctx, t, content, new_content, verb);
}
fn cmdToggle(ctx: *Ctx, t: Target, content: []const u8, ids: [][]const u8, enable: bool) !void {
    var ct = try parseCrontab(ctx.a, content); var touched: usize = 0;
    for (ids) |id| { if (ct.findIndex(id)) |i| { ct.items.items[i].job.enabled = enable; touched += 1; } else { eprint("looper: no managed job '{s}' on {s}\n", .{id, t.label(ctx.a)}); g_fail(); } }
    if (touched == 0) return;
    const new_content = try serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "{s} {d} job(s)", .{ if (enable) "enabled" else "disabled", touched });
    try applyMutation(ctx, t, content, new_content, verb);
}
fn cmdRm(ctx: *Ctx, t: Target, content: []const u8, ids: [][]const u8) !void {
    var ct = try parseCrontab(ctx.a, content);
    var rm: std.ArrayList(usize) = .empty;
    for (ids) |id| {
        if (ct.findIndex(id)) |i| { try rm.append(ctx.a, i); continue; }
        if (id.len >= 2 and id[0] == 'f' and allDigits(id[1..])) {
            const n = std.fmt.parseInt(usize, id[1..], 10) catch 0;
            if (ct.findForeign(n)) |i| { try rm.append(ctx.a, i); continue; }
        }
        eprint("looper: no job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        g_fail();
    }
    if (rm.items.len == 0) return;
    if (!confirm(ctx, "Remove {d} job(s) from {s}?", .{rm.items.len, t.label(ctx.a)})) { ctx.emit("aborted\n", .{}); return; }
    var keep: std.ArrayList(Item) = .empty;
    outer: for (ct.items.items, 0..) |it, idx| { for (rm.items) |ri| if (ri == idx) continue :outer; try keep.append(ctx.a, it); }
    ct.items = keep;
    const new_content = try serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "removed {d} job(s)", .{rm.items.len});
    try applyMutation(ctx, t, content, new_content, verb);
}
fn cmdShow(ctx: *Ctx, t: Target, content: []const u8, id: []const u8) !void {
    const ct = try parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse { eprint("looper: no managed job '{s}' on {s}\n", .{id, t.label(ctx.a)}); g_fail(); return; };
    const j = ct.items.items[idx].job;
    ctx.emit("{s}{s}{s}{s}  {s}{s}{s}\n", .{ ctx.k(BOLD), ctx.k(CYAN), j.id, ctx.k(RESET), if (j.enabled) ctx.k(GREEN) else ctx.k(DIM), if (j.enabled) "enabled" else "disabled", ctx.k(RESET) });
    ctx.emit("  schedule : {s}{s}{s}\n", .{ctx.k(DIM), j.schedule, ctx.k(RESET)});
    ctx.emit("  meaning  : {s}\n", .{humanize(ctx.a, j.schedule)});
    ctx.emit("  command  : {s}\n", .{j.command});
    ctx.emit("  target   : {s}\n", .{t.label(ctx.a)});
    const sched = parseSchedule(j.schedule) catch { ctx.emit("  next     : (does not parse)\n", .{}); return; };
    if (sched.reboot) { ctx.emit("  next     : at next reboot\n", .{}); return; }
    ctx.emit("  next 5   :\n", .{});
    var from = nowEpoch(); var k: usize = 0;
    while (k < 5) : (k += 1) { const nr = nextRun(sched, from) orelse break; ctx.emit("    {s}\n", .{fmtWhen(ctx.a, nr)}); from = nr; }
    if (t.kind == .remote) ctx.emit("  {s}(next-run times use this machine's timezone){s}\n", .{ctx.k(DIM), ctx.k(RESET)});
}
fn cmdRun(ctx: *Ctx, t: Target, content: []const u8, id: []const u8) !void {
    const ct = try parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse { eprint("looper: no managed job '{s}' on {s}\n", .{id, t.label(ctx.a)}); g_fail(); return; };
    const cmd = ct.items.items[idx].job.command;
    ctx.emit("{s}running '{s}' on {s}…{s}\n", .{ctx.k(DIM), id, t.label(ctx.a), ctx.k(RESET)}); ctx.flush();
    var argv: std.ArrayList([]const u8) = .empty;
    if (t.kind == .remote) { try argv.append(ctx.a, "ssh"); try argv.append(ctx.a, t.host); try argv.append(ctx.a, cmd); }
    else { try argv.append(ctx.a, "/bin/sh"); try argv.append(ctx.a, "-c"); try argv.append(ctx.a, cmd); }
    const code = runInherit(ctx.a, argv.items) catch 1;
    if (code != 0) g_fail();
    ctx.emit("{s}exit {d}{s}\n", .{ if (code == 0) ctx.k(GREEN) else ctx.k(RED), code, ctx.k(RESET) });
}
fn cmdExplain(ctx: *Ctx, input: []const u8) !void {
    const schedule = toCron(ctx.a, input) orelse {
        eprint("looper: couldn't read schedule '{s}'\n", .{input});
        eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        g_fail(); return;
    };
    const sched = parseSchedule(schedule) catch |e| { eprint("looper: invalid schedule '{s}': {s}\n", .{schedule, @errorName(e)}); g_fail(); return; };
    if (!std.mem.eql(u8, schedule, input))
        ctx.emit("{s}\"{s}\"{s} \xe2\x86\x92 {s}{s}{s}\n", .{ ctx.k(DIM), input, ctx.k(RESET), ctx.k(BOLD), schedule, ctx.k(RESET) })
    else
        ctx.emit("{s}{s}{s}\n", .{ctx.k(BOLD), schedule, ctx.k(RESET)});
    ctx.emit("  {s}\n", .{humanize(ctx.a, schedule)});
    if (sched.reboot) { ctx.emit("  runs once at boot\n", .{}); return; }
    ctx.emit("  next runs:\n", .{});
    var from = nowEpoch(); var k: usize = 0;
    while (k < 5) : (k += 1) { const nr = nextRun(sched, from) orelse break; ctx.emit("    {s}\n", .{fmtWhen(ctx.a, nr)}); from = nr; }
}
fn cmdBackup(ctx: *Ctx, t: Target, content: []const u8) !void {
    const p = doBackup(ctx.a, t, content) orelse { eprint("looper: backup failed\n", .{}); g_fail(); return; };
    ctx.emit("{s}\xe2\x9c\x93{s} backed up {s} to {s}\n", .{ctx.k(GREEN), ctx.k(RESET), t.label(ctx.a), p});
}
fn cmdRestore(ctx: *Ctx, t: Target, current: []const u8, given: ?[]const u8) !void {
    const path = given orelse newestBackup(ctx.a, t) orelse { eprint("looper: no backups for {s}\n", .{t.label(ctx.a)}); g_fail(); return; };
    const data = readFileAll(ctx.a, path) catch { eprint("looper: cannot read backup {s}\n", .{path}); g_fail(); return; };
    ctx.emit("{s}restoring {s} from {s}{s}\n", .{ctx.k(DIM), t.label(ctx.a), path, ctx.k(RESET)});
    try applyMutation(ctx, t, current, data, "restored snapshot");
}
fn cmdImport(ctx: *Ctx, t: Target, content: []const u8) !void {
    var ct = try parseCrontab(ctx.a, content); var n: usize = 0;
    for (ct.items.items) |*it| switch (it.*) { .job => |*j| if (j.foreign) { j.foreign = false; j.enabled = true; j.id = slugUnique(ctx.a, &ct, j.command); n += 1; }, else => {} };
    if (n == 0) { ctx.emit("{s}no unmanaged jobs to import on {s}{s}\n", .{ctx.k(DIM), t.label(ctx.a), ctx.k(RESET)}); return; }
    const new_content = try serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "imported {d} job(s)", .{n});
    try applyMutation(ctx, t, content, new_content, verb);
}

fn printHelp(ctx: *Ctx) void {
    const B = ctx.k(BOLD); const R = ctx.k(RESET); const D = ctx.k(DIM);
    ctx.emit("{s}looper{s} {s}1.0.0{s}  manage cron jobs, one or many, local or over ssh.\n\n", .{B, R, D, R});
    ctx.emit("{s}USAGE{s}\n", .{B, R});
    ctx.emit("  looper <command> [arguments] [options]\n", .{});
    ctx.emit("\n", .{});
    ctx.emit("{s}COMMANDS{s}\n", .{B, R});
    ctx.emit("  ls                        List jobs with their next run times\n", .{});
    ctx.emit("  add <schedule> <command>  Add or update a job (idempotent; name with --id)\n", .{});
    ctx.emit("  rm <id|fN>...             Remove job(s): by id, or unmanaged ones by fN handle\n", .{});
    ctx.emit("  enable <id>...            Re-enable a disabled job\n", .{});
    ctx.emit("  disable <id>...           Pause a job, keeping its definition\n", .{});
    ctx.emit("  show <id>                 Explain a job: meaning + next 5 run times\n", .{});
    ctx.emit("  run <id>                  Run a job's command now, streaming output\n", .{});
    ctx.emit("  explain <schedule>        Describe a schedule (cron or English; no changes)\n", .{});
    ctx.emit("  import                    Adopt existing, unmanaged crontab jobs\n", .{});
    ctx.emit("  backup                    Snapshot the crontab to the state directory\n", .{});
    ctx.emit("  restore [file]            Roll back to the newest (or named) snapshot\n", .{});
    ctx.emit("  help, version\n", .{});
    ctx.emit("\n", .{});
    ctx.emit("{s}TARGET{s} {s}(default: your own local crontab){s}\n", .{B, R, D, R});
    ctx.emit("  -H, --host <[user@]host>  A remote host via ssh (repeatable)\n", .{});
    ctx.emit("      --all                 Every host in ~/.config/looper/hosts\n", .{});
    ctx.emit("  -u, --user <name>         Another user's crontab\n", .{});
    ctx.emit("  -f, --file <path>         A crontab file (handy for git)\n", .{});
    ctx.emit("\n", .{});
    ctx.emit("{s}OPTIONS{s}\n", .{B, R});
    ctx.emit("      --dry-run             Show the change as a diff; write nothing\n", .{});
    ctx.emit("  -y, --yes                 Skip confirmation prompts\n", .{});
    ctx.emit("      --json                Machine-readable output (for ls)\n", .{});
    ctx.emit("  -q, --quiet               Print only errors\n", .{});
    ctx.emit("      --no-color            Disable color (also obeys NO_COLOR)\n", .{});
    ctx.emit("  -h, --help                Show this help\n", .{});
    ctx.emit("\n", .{});
    ctx.emit("{s}SCHEDULES{s} {s}- cron, a macro, or plain English, all stored as standard cron{s}\n", .{B, R, D, R});
    ctx.emit("    cron                    */15 9-17 * * mon-fri\n", .{});
    ctx.emit("    macro                   @yearly @monthly @weekly @daily @hourly @reboot\n", .{});
    ctx.emit("    english                 \"every weekday at 9:30am\", \"at noon on sundays\"\n", .{});
    ctx.emit("\n", .{});
    ctx.emit("{s}EXAMPLES{s}\n", .{B, R});
    ctx.emit("  {s}  {s}# nightly at 3am{s}\n", .{ "looper add \"0 3 * * *\" backup.sh              ", D, R });
    ctx.emit("  {s}  {s}# plain English{s}\n", .{ "looper add \"every weekday at 8am\" report.sh   ", D, R });
    ctx.emit("  {s}  {s}# preview, no changes{s}\n", .{ "looper explain \"at noon on weekends\"          ", D, R });
    ctx.emit("  {s}  {s}# remove an unmanaged job (see ls){s}\n", .{ "looper rm f1                                  ", D, R });
    ctx.emit("  {s}  {s}# every host in the fleet{s}\n", .{ "looper --all ls                               ", D, R });
    ctx.emit("\n", .{});
    ctx.emit("Every change is backed up first; there is deliberately no \"delete everything\".\n", .{});
}
const Cmd = enum { ls, add, rm, enable, disable, show, run, explain, import, backup, restore, version, help, unknown };
fn parseCmd(s: []const u8) Cmd {
    const map = .{
        .{ "ls", Cmd.ls }, .{ "list", Cmd.ls }, .{ "add", Cmd.add }, .{ "set", Cmd.add },
        .{ "rm", Cmd.rm }, .{ "remove", Cmd.rm }, .{ "delete", Cmd.rm },
        .{ "enable", Cmd.enable }, .{ "disable", Cmd.disable }, .{ "show", Cmd.show },
        .{ "run", Cmd.run }, .{ "explain", Cmd.explain }, .{ "import", Cmd.import },
        .{ "backup", Cmd.backup }, .{ "restore", Cmd.restore }, .{ "version", Cmd.version }, .{ "help", Cmd.help },
    };
    inline for (map) |pair| if (std.mem.eql(u8, s, pair[0])) return pair[1];
    return .unknown;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Ctx{ .a = a };
    ctx.color = c.isatty(1) != 0 and getenv("NO_COLOR") == null;

    const argv = try init.args.toSlice(a);

    var positionals: std.ArrayList([]const u8) = .empty;
    var hosts: std.ArrayList([]const u8) = .empty;
    var use_all = false; var user: []const u8 = ""; var file_path: []const u8 = "";
    var want_id: ?[]const u8 = null; var force_help = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) { i += 1; while (i < argv.len) : (i += 1) try positionals.append(a, argv[i]); break; }
        else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) { i += 1; if (i < argv.len) try hosts.append(a, argv[i]); }
        else if (std.mem.eql(u8, arg, "--all")) use_all = true
        else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) { i += 1; if (i < argv.len) user = argv[i]; }
        else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) { i += 1; if (i < argv.len) file_path = argv[i]; }
        else if (std.mem.eql(u8, arg, "--id")) { i += 1; if (i < argv.len) want_id = argv[i]; }
        else if (std.mem.eql(u8, arg, "--dry-run")) ctx.dry_run = true
        else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) ctx.yes = true
        else if (std.mem.eql(u8, arg, "--json")) ctx.json = true
        else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) ctx.quiet = true
        else if (std.mem.eql(u8, arg, "--no-color")) ctx.color = false
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) force_help = true
        else if (arg.len > 1 and arg[0] == '-' and !std.ascii.isDigit(arg[1])) { eprint("looper: unknown option '{s}' (try: looper help)\n", .{arg}); std.process.exit(2); }
        else try positionals.append(a, arg);
    }

    if (force_help or positionals.items.len == 0) { printHelp(&ctx); ctx.flush(); return; }
    const cmd = parseCmd(positionals.items[0]);
    const rest = positionals.items[1..];
    if (cmd == .help) { printHelp(&ctx); ctx.flush(); return; }
    if (cmd == .version) { ctx.emit("looper {s}\n", .{VERSION}); ctx.flush(); return; }
    if (cmd == .unknown) { eprint("looper: unknown command '{s}' (try: looper help)\n", .{positionals.items[0]}); std.process.exit(2); }
    if (cmd == .explain) {
        if (rest.len < 1) { eprint("looper: explain needs a schedule\n", .{}); std.process.exit(2); }
        try cmdExplain(&ctx, rest[0]); ctx.flush(); return;
    }

    if (file_path.len == 0 and hosts.items.len == 0 and !use_all) {
        if (getenv("LOOPER_CRONTAB_FILE")) |fp| file_path = fp;
    }
    var targets: std.ArrayList(Target) = .empty;
    if (use_all) {
        const cfg = if (getenv("XDG_CONFIG_HOME")) |x| (std.fmt.allocPrint(a, "{s}/looper/hosts", .{x}) catch "") else (std.fmt.allocPrint(a, "{s}/.config/looper/hosts", .{getenv("HOME") orelse "."}) catch "");
        const body = readFileAll(a, cfg) catch "";
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| { const h = std.mem.trim(u8, line, " \t\r"); if (h.len == 0 or h[0] == '#') continue; try targets.append(a, .{ .kind = .remote, .host = h, .user = user }); }
        if (targets.items.len == 0) { eprint("looper: --all but no hosts in {s}\n", .{cfg}); return; }
    } else if (hosts.items.len > 0) {
        for (hosts.items) |h| try targets.append(a, .{ .kind = .remote, .host = h, .user = user });
    } else if (file_path.len > 0) {
        try targets.append(a, .{ .kind = .file, .path = file_path });
    } else try targets.append(a, .{ .kind = .local, .user = user });

    const multi = targets.items.len > 1;
    for (targets.items) |t| {
        if (multi) ctx.emit("{s}{s}=== {s} ==={s}\n", .{ctx.k(BOLD), ctx.k(BLUE), t.label(a), ctx.k(RESET)});
        const content = readCrontab(a, t) catch |e| {
            eprint("looper: cannot read crontab on {s}: {s}\n", .{t.label(a), @errorName(e)});
            if (e == BackendError.Unavailable) eprint("  (is 'crontab'/'ssh' installed and reachable?)\n", .{});
            continue;
        };
        switch (cmd) {
            .ls => try cmdLs(&ctx, t, content),
            .add => { if (rest.len < 2) { eprint("looper: add needs <schedule> <command>\n", .{}); g_fail(); break; } try cmdAdd(&ctx, t, content, rest[0], rest[1], want_id); },
            .rm => { if (rest.len < 1) { eprint("looper: rm needs an id\n", .{}); g_fail(); break; } try cmdRm(&ctx, t, content, rest); },
            .enable => try cmdToggle(&ctx, t, content, rest, true),
            .disable => try cmdToggle(&ctx, t, content, rest, false),
            .show => { if (rest.len < 1) { eprint("looper: show needs an id\n", .{}); g_fail(); break; } try cmdShow(&ctx, t, content, rest[0]); },
            .run => { if (rest.len < 1) { eprint("looper: run needs an id\n", .{}); g_fail(); break; } try cmdRun(&ctx, t, content, rest[0]); },
            .import => try cmdImport(&ctx, t, content),
            .backup => try cmdBackup(&ctx, t, content),
            .restore => try cmdRestore(&ctx, t, content, if (rest.len > 0) rest[0] else null),
            else => {},
        }
        if (multi) ctx.emit("\n", .{});
        ctx.flush();
    }
    ctx.flush();
    if (g_exit != 0) std.process.exit(g_exit);
}
