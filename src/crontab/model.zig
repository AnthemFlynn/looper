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
    /// One-shot: fires once at the scheduled time, then `_exec` removes
    /// the job from the crontab. The cron schedule (M H D Mo *) still
    /// repeats annually, so self-removal is what makes it "once".
    once: bool = false,
    /// When set, the cron payload is a `looper _exec --run-id=X --` wrapper
    /// that captures stdout/stderr to `state_dir/runs/<run_id>/`. For
    /// recurring jobs with capture, `_exec` generates a fresh run_id per
    /// invocation; the marker's run_id is just the "series" anchor.
    capture: bool = false,
    /// Series anchor for one-shots; null for plain recurring jobs.
    run_id: ?[]const u8 = null,
    /// Max wall-clock seconds before `_exec` kills the child. Null = no limit.
    timeout_secs: ?u32 = null,
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

pub const Marker = struct {
    id: []const u8,
    enabled: bool,
    once: bool = false,
    capture: bool = false,
    run_id: ?[]const u8 = null,
    timeout_secs: ?u32 = null,
};

pub fn parseMarker(a: std.mem.Allocator, line: []const u8) ?Marker {
    if (!std.mem.startsWith(u8, line, MARKER)) return null;
    var id: []const u8 = "";
    var enabled = true;
    var once = false;
    var capture = false;
    var run_id: ?[]const u8 = null;
    var timeout_secs: ?u32 = null;
    var it = std.mem.tokenizeAny(u8, line[MARKER.len..], " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "id=")) id = a.dupe(u8, tok[3..]) catch tok[3..];
        if (std.mem.startsWith(u8, tok, "enabled=")) enabled = std.mem.eql(u8, tok[8..], "1");
        if (std.mem.startsWith(u8, tok, "once=")) once = std.mem.eql(u8, tok[5..], "1");
        if (std.mem.startsWith(u8, tok, "capture=")) capture = std.mem.eql(u8, tok[8..], "1");
        if (std.mem.startsWith(u8, tok, "run_id=")) run_id = a.dupe(u8, tok[7..]) catch tok[7..];
        if (std.mem.startsWith(u8, tok, "timeout_secs=")) timeout_secs = std.fmt.parseInt(u32, tok[13..], 10) catch null;
    }
    if (id.len == 0) return null;
    return .{ .id = id, .enabled = enabled, .once = once, .capture = capture, .run_id = run_id, .timeout_secs = timeout_secs };
}

/// Reconstructs a marker line from its struct form. Used by both the
/// serializer and the parser's fallback paths so the format lives in
/// exactly one place. Optional attributes are omitted when not set,
/// keeping byte-stable round-trip for plain (non-once, non-capture) jobs.
pub fn serializeMarker(a: std.mem.Allocator, m: Marker) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    ctx_mod.aw(a, &out, "{s} id={s} enabled={d}", .{ MARKER, m.id, @as(u8, if (m.enabled) 1 else 0) });
    if (m.once) ctx_mod.aw(a, &out, " once=1", .{});
    if (m.capture) ctx_mod.aw(a, &out, " capture=1", .{});
    if (m.run_id) |rid| ctx_mod.aw(a, &out, " run_id={s}", .{rid});
    if (m.timeout_secs) |t| ctx_mod.aw(a, &out, " timeout_secs={d}", .{t});
    return out.toOwnedSlice(a);
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
                try ct.items.append(a, .{ .job = .{
                    .id = pm.id,
                    .enabled = pm.enabled,
                    .schedule = try a.dupe(u8, sc.sched),
                    .command = try a.dupe(u8, sc.cmd),
                    .once = pm.once,
                    .capture = pm.capture,
                    .run_id = pm.run_id,
                    .timeout_secs = pm.timeout_secs,
                } });
            } else {
                try ct.items.append(a, .{ .raw = try serializeMarker(a, pm) });
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
    if (pending) |pm| try ct.items.append(a, .{ .raw = try serializeMarker(a, pm) });
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
                const marker_line = try serializeMarker(a, .{
                    .id = j.id,
                    .enabled = j.enabled,
                    .once = j.once,
                    .capture = j.capture,
                    .run_id = j.run_id,
                    .timeout_secs = j.timeout_secs,
                });
                try out.appendSlice(a, marker_line);
                try out.append(a, '\n');
                if (j.enabled) ctx_mod.aw(a, &out, "{s} {s}\n", .{ j.schedule, j.command }) else ctx_mod.aw(a, &out, "# {s} {s}\n", .{ j.schedule, j.command });
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

// ---------------------------------------------------------------------------
// Forward-compat: extended marker attributes (once, capture, run_id, timeout_secs)
// ---------------------------------------------------------------------------

test "parseMarker old-style (id+enabled only) defaults new fields" {
    // The contract: an existing crontab written by a pre-extension looper
    // continues to parse, with the new attributes taking their type defaults.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(arena.allocator(), "#looper# id=demo enabled=1").?;
    try testing.expectEqualStrings("demo", m.id);
    try testing.expect(m.enabled);
    try testing.expect(!m.once);
    try testing.expect(!m.capture);
    try testing.expectEqual(@as(?[]const u8, null), m.run_id);
    try testing.expectEqual(@as(?u32, null), m.timeout_secs);
}

test "parseMarker reads once + capture + run_id + timeout_secs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(
        arena.allocator(),
        "#looper# id=test once=1 capture=1 run_id=abc123 timeout_secs=300 enabled=1",
    ).?;
    try testing.expectEqualStrings("test", m.id);
    try testing.expect(m.enabled);
    try testing.expect(m.once);
    try testing.expect(m.capture);
    try testing.expectEqualStrings("abc123", m.run_id.?);
    try testing.expectEqual(@as(?u32, 300), m.timeout_secs);
}

test "parseMarker token order is insensitive" {
    // Whichever order the writer used, the parser must extract the same struct.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m1 = parseMarker(a, "#looper# id=x enabled=1 once=1 run_id=r1").?;
    const m2 = parseMarker(a, "#looper# run_id=r1 once=1 id=x enabled=1").?;
    try testing.expectEqualStrings(m1.id, m2.id);
    try testing.expectEqual(m1.enabled, m2.enabled);
    try testing.expectEqual(m1.once, m2.once);
    try testing.expectEqualStrings(m1.run_id.?, m2.run_id.?);
}

test "parseMarker ignores unknown tokens (forward-compat from v2+ crontabs)" {
    // If a future looper version writes new attributes we don't understand,
    // we must keep parsing — drop the unknowns, retain the rest.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(
        arena.allocator(),
        "#looper# id=x enabled=1 future_attr=42 also_unknown=hello once=1",
    ).?;
    try testing.expectEqualStrings("x", m.id);
    try testing.expect(m.enabled);
    try testing.expect(m.once);
}

test "parseMarker rejects malformed timeout_secs gracefully" {
    // parseInt errors should surface as a null timeout, not a crash.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(arena.allocator(), "#looper# id=x enabled=1 timeout_secs=not-a-number").?;
    try testing.expectEqual(@as(?u32, null), m.timeout_secs);
}

test "serializeMarker omits unset attributes (old jobs stay byte-stable)" {
    // The first half of the forward-compat contract: a job that doesn't use
    // the new fields must serialize to the exact bytes a pre-extension
    // looper would have written.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try serializeMarker(a, .{ .id = "demo", .enabled = true });
    try testing.expectEqualStrings("#looper# id=demo enabled=1", out);
}

test "serializeMarker emits all set attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try serializeMarker(a, .{
        .id = "demo",
        .enabled = true,
        .once = true,
        .capture = true,
        .run_id = "abc123",
        .timeout_secs = 300,
    });
    try testing.expectEqualStrings(
        "#looper# id=demo enabled=1 once=1 capture=1 run_id=abc123 timeout_secs=300",
        out,
    );
}

test "parseCrontab propagates extended attrs into Job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=oneshot enabled=1 once=1 capture=1 run_id=r-42 timeout_secs=120
        \\57 14 23 5 * /usr/local/bin/looper _exec --run-id=r-42 -- /bin/echo hi
        \\
    ;
    const ct = try parseCrontab(a, input);
    try testing.expectEqual(@as(usize, 1), ct.items.items.len);
    switch (ct.items.items[0]) {
        .job => |j| {
            try testing.expectEqualStrings("oneshot", j.id);
            try testing.expect(j.enabled);
            try testing.expect(j.once);
            try testing.expect(j.capture);
            try testing.expectEqualStrings("r-42", j.run_id.?);
            try testing.expectEqual(@as(?u32, 120), j.timeout_secs);
        },
        else => return error.UnexpectedItem,
    }
}

test "serialize roundtrip preserves new attributes byte-for-byte" {
    // The second half of the forward-compat contract: a job that DOES use
    // the new fields round-trips through parse → serialize → bytes unchanged.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=oneshot enabled=1 once=1 capture=1 run_id=r-42 timeout_secs=120
        \\57 14 23 5 * /usr/local/bin/looper _exec --run-id=r-42 -- /bin/echo hi
        \\
    ;
    var ct = try parseCrontab(a, input);
    const out = try serialize(a, &ct);
    try testing.expectEqualStrings(input, out);
}

test "serialize roundtrip mixed (old + new) markers preserves bytes" {
    // Realistic transition state: a crontab with both pre-extension jobs and
    // new one-shot jobs side-by-side must round-trip without either side
    // bleeding into the other's serialization.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=daily-backup enabled=1
        \\0 3 * * * /usr/local/bin/backup.sh
        \\#looper# id=test-run enabled=1 once=1 run_id=abc
        \\57 14 23 5 * /usr/local/bin/looper _exec --run-id=abc -- /bin/echo hi
        \\
    ;
    var ct = try parseCrontab(a, input);
    const out = try serialize(a, &ct);
    try testing.expectEqualStrings(input, out);
}
