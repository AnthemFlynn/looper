//! Crontab file model + parser/serializer. A managed job is two lines
//! in the crontab — a `#looper#` marker, then the real cron payload.
//! Unmanaged ("foreign") lines and environment assignments are preserved
//! verbatim.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");

pub const MARKER = "#looper#";

pub const Job = struct {
    id: []const u8,
    enabled: bool,
    schedule: []const u8,
    command: []const u8,
    foreign: bool = false,
};

pub const Item = union(enum) {
    raw: []const u8,
    job: Job,
};

pub const Crontab = struct {
    items: std.ArrayList(Item) = .empty,
    pub fn findIndex(self: *const Crontab, id: []const u8) ?usize {
        for (self.items.items, 0..) |it, i| switch (it) {
            .job => |j| if (!j.foreign and std.mem.eql(u8, j.id, id)) return i,
            else => {},
        };
        return null;
    }
    /// item index of the nth (1-based) unmanaged job, as listed by `ls`
    pub fn findForeign(self: *const Crontab, n: usize) ?usize {
        var k: usize = 0;
        for (self.items.items, 0..) |it, i| switch (it) {
            .job => |j| if (j.foreign) {
                k += 1;
                if (k == n) return i;
            },
            else => {},
        };
        return null;
    }
};

pub fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub const SC = struct { sched: []const u8, cmd: []const u8 };
pub fn splitScheduleCommand(line_in: []const u8) ?SC {
    const line = std.mem.trim(u8, line_in, " \t");
    if (line.len == 0) return null;
    if (line[0] == '@') {
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse return null;
        return .{ .sched = line[0..sp], .cmd = std.mem.trimStart(u8, line[sp..], " \t") };
    }
    var idx: usize = 0;
    var fc: usize = 0;
    var in_field = false;
    var fifth_end: usize = 0;
    while (idx < line.len) : (idx += 1) {
        const ws = line[idx] == ' ' or line[idx] == '\t';
        if (!ws and !in_field) {
            in_field = true;
            fc += 1;
        } else if (ws and in_field) {
            in_field = false;
            if (fc == 5) {
                fifth_end = idx;
                break;
            }
        }
    }
    if (fc < 5 or fifth_end == 0) return null;
    return .{ .sched = line[0..fifth_end], .cmd = std.mem.trimStart(u8, line[fifth_end..], " \t") };
}

pub fn isEnvAssignment(line: []const u8) bool {
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

pub const Marker = struct { id: []const u8, enabled: bool };
pub fn parseMarker(a: std.mem.Allocator, line: []const u8) ?Marker {
    if (!std.mem.startsWith(u8, line, MARKER)) return null;
    var id: []const u8 = "";
    var enabled = true;
    var it = std.mem.tokenizeAny(u8, line[MARKER.len..], " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "id=")) id = a.dupe(u8, tok[3..]) catch tok[3..];
        if (std.mem.startsWith(u8, tok, "enabled=")) enabled = std.mem.eql(u8, tok[8..], "1");
    }
    if (id.len == 0) return null;
    return .{ .id = id, .enabled = enabled };
}

pub fn parseCrontab(a: std.mem.Allocator, text: []const u8) !Crontab {
    var ct = Crontab{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var pending: ?Marker = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (pending) |pm| {
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            var payload = line;
            if (!pm.enabled) {
                const t = std.mem.trimStart(u8, line, " \t");
                if (std.mem.startsWith(u8, t, "#")) payload = std.mem.trimStart(u8, t[1..], " \t");
            }
            if (splitScheduleCommand(payload)) |sc| {
                try ct.items.append(a, .{ .job = .{ .id = pm.id, .enabled = pm.enabled, .schedule = try a.dupe(u8, sc.sched), .command = try a.dupe(u8, sc.cmd) } });
            } else {
                try ct.items.append(a, .{ .raw = try std.fmt.allocPrint(a, "{s} id={s} enabled={d}", .{ MARKER, pm.id, @as(u8, if (pm.enabled) 1 else 0) }) });
                try ct.items.append(a, .{ .raw = try a.dupe(u8, line) });
            }
            pending = null;
            continue;
        }
        if (parseMarker(a, line)) |mk| {
            pending = mk;
            continue;
        }
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
    if (ct.items.items.len > 0) {
        const last = ct.items.items[ct.items.items.len - 1];
        if (last == .raw and last.raw.len == 0) _ = ct.items.pop();
    }
    return ct;
}

pub fn serialize(a: std.mem.Allocator, ct: *Crontab) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ct.items.items) |it| switch (it) {
        .raw => |r| {
            try out.appendSlice(a, r);
            try out.append(a, '\n');
        },
        .job => |j| {
            if (j.foreign) {
                ctx_mod.aw(a, &out, "{s} {s}\n", .{ j.schedule, j.command });
            } else {
                ctx_mod.aw(a, &out, "{s} id={s} enabled={d}\n", .{ MARKER, j.id, @as(u8, if (j.enabled) 1 else 0) });
                if (j.enabled) ctx_mod.aw(a, &out, "{s} {s}\n", .{ j.schedule, j.command })
                else ctx_mod.aw(a, &out, "# {s} {s}\n", .{ j.schedule, j.command });
            }
        },
    };
    return out.toOwnedSlice(a);
}

const testing = std.testing;

test "splitScheduleCommand standard 5-field" {
    const sc = splitScheduleCommand("0 3 * * * /usr/local/bin/backup.sh").?;
    try testing.expectEqualStrings("0 3 * * *", sc.sched);
    try testing.expectEqualStrings("/usr/local/bin/backup.sh", sc.cmd);
}

test "splitScheduleCommand @macro" {
    const sc = splitScheduleCommand("@reboot /opt/start.sh").?;
    try testing.expectEqualStrings("@reboot", sc.sched);
    try testing.expectEqualStrings("/opt/start.sh", sc.cmd);
}

test "splitScheduleCommand fewer than 5 fields rejected" {
    try testing.expectEqual(@as(?SC, null), splitScheduleCommand("0 3 * *"));
}

test "splitScheduleCommand empty rejected" {
    try testing.expectEqual(@as(?SC, null), splitScheduleCommand(""));
    try testing.expectEqual(@as(?SC, null), splitScheduleCommand("   "));
}

test "isEnvAssignment identifies PATH=/usr/bin" {
    try testing.expect(isEnvAssignment("PATH=/usr/bin"));
    try testing.expect(isEnvAssignment("MAILTO=ops@example.com"));
    try testing.expect(isEnvAssignment("_PRIVATE=42"));
}

test "isEnvAssignment rejects cron lines" {
    try testing.expect(!isEnvAssignment("0 3 * * * cmd"));
    try testing.expect(!isEnvAssignment("@reboot cmd"));
    try testing.expect(!isEnvAssignment(""));
    try testing.expect(!isEnvAssignment("=value"));
}

test "parseMarker valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(arena.allocator(), "#looper# id=foo enabled=1").?;
    try testing.expectEqualStrings("foo", m.id);
    try testing.expect(m.enabled);
}

test "parseMarker enabled=0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(arena.allocator(), "#looper# id=bar enabled=0").?;
    try testing.expectEqualStrings("bar", m.id);
    try testing.expect(!m.enabled);
}

test "parseMarker no id is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?Marker, null), parseMarker(arena.allocator(), "#looper# enabled=1"));
}

test "parseCrontab preserves foreign lines and env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\PATH=/usr/local/bin:/usr/bin
        \\# a comment
        \\0 6 * * 1 /opt/foreign.sh
        \\
    ;
    const ct = try parseCrontab(a, input);
    var foreigners: usize = 0;
    var raws: usize = 0;
    for (ct.items.items) |it| switch (it) {
        .job => |j| if (j.foreign) {
            foreigners += 1;
        },
        .raw => raws += 1,
    };
    try testing.expectEqual(@as(usize, 1), foreigners);
    try testing.expectEqual(@as(usize, 2), raws); // PATH= and the comment line
}

test "parseCrontab marker + payload becomes managed job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=db-backup enabled=1
        \\0 3 * * * /usr/local/bin/backup.sh
        \\
    ;
    const ct = try parseCrontab(a, input);
    try testing.expectEqual(@as(usize, 1), ct.items.items.len);
    switch (ct.items.items[0]) {
        .job => |j| {
            try testing.expectEqualStrings("db-backup", j.id);
            try testing.expect(j.enabled);
            try testing.expect(!j.foreign);
            try testing.expectEqualStrings("0 3 * * *", j.schedule);
            try testing.expectEqualStrings("/usr/local/bin/backup.sh", j.command);
        },
        else => return error.UnexpectedItem,
    }
}

test "parseCrontab disabled job round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=paused enabled=0
        \\# 0 4 * * * /opt/maint.sh
        \\
    ;
    const ct = try parseCrontab(a, input);
    switch (ct.items.items[0]) {
        .job => |j| {
            try testing.expect(!j.enabled);
            try testing.expectEqualStrings("0 4 * * *", j.schedule);
            try testing.expectEqualStrings("/opt/maint.sh", j.command);
        },
        else => return error.UnexpectedItem,
    }
}

test "serialize roundtrip preserves byte content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\PATH=/usr/local/bin
        \\#looper# id=db-backup enabled=1
        \\0 3 * * * /usr/local/bin/backup.sh
        \\#looper# id=paused enabled=0
        \\# 0 4 * * * /opt/maint.sh
        \\@daily /usr/local/bin/foreign.sh
        \\
    ;
    var ct = try parseCrontab(a, input);
    const out = try serialize(a, &ct);
    try testing.expectEqualStrings(input, out);
}

test "Crontab findIndex finds managed by id, skips foreign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=foo enabled=1
        \\0 3 * * * cmd
        \\@daily other
        \\
    ;
    const ct = try parseCrontab(a, input);
    try testing.expectEqual(@as(?usize, 0), ct.findIndex("foo"));
    try testing.expectEqual(@as(?usize, null), ct.findIndex("nope"));
    try testing.expectEqual(@as(?usize, 1), ct.findForeign(1));
}
