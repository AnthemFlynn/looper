//! Crontab file model + parser/serializer. A managed job is two lines
//! in the crontab — a `#looper#` marker, then the real cron payload.
//! Unmanaged ("foreign") lines and environment assignments are preserved
//! verbatim.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const posix = @import("../posix.zig");

pub const MARKER = "#looper#";

pub const Job = struct {
    id: []const u8,
    enabled: bool,
    schedule: []const u8,
    /// The USER'S command — the inner command the wrapper invokes.
    /// For non-wrapped jobs this is just the cron payload verbatim;
    /// for wrapped jobs (`once=1` or `capture=1`) the wrapper is
    /// reconstructed at serialize time from `wrapper_bin` + marker
    /// flags, and stripped back to this inner form at parse time.
    /// `looper ls` and friends always see the user's intent.
    command: []const u8,
    foreign: bool = false,
    /// One-shot: fires once at the scheduled time, then `_exec` removes
    /// the job from the crontab. The cron schedule (M H D Mo *) still
    /// repeats annually, so self-removal is what makes it "once".
    once: bool = false,
    /// When set, the cron payload is a `looper _exec ...` wrapper that
    /// captures stdout/stderr to `state_dir/runs/<run_id>/`. For recurring
    /// jobs with capture, `_exec` generates a fresh run_id per invocation;
    /// the marker's run_id is just the "series" anchor.
    capture: bool = false,
    /// Series anchor for one-shots; null for plain recurring jobs.
    run_id: ?[]const u8 = null,
    /// Max wall-clock seconds before `_exec` kills the child. Null = no limit.
    timeout_secs: ?u32 = null,
    /// Absolute path to the looper binary that was current when this
    /// wrapped job was written. Embedded in the cron payload so the job
    /// keeps firing the right binary even if looper later moves or a
    /// shell PATH change would have broken bare-name lookup. Null for
    /// non-wrapped jobs.
    wrapper_bin: ?[]const u8 = null,
    /// Provenance: the principal (--as / LOOPER_AS) that originally
    /// created this job. Null for jobs written by a pre-provenance
    /// looper or hand-edited markers. Stable across edits — only
    /// `last_modified_by` changes.
    created_by: ?[]const u8 = null,
    created_at: ?i64 = null,
    last_modified_by: ?[]const u8 = null,
    last_modified_at: ?i64 = null,
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
    /// Looper-binary path embedded at write time. The cron payload is
    /// synthesized from this + marker flags at serialize time.
    wrapper_bin: ?[]const u8 = null,
    /// Provenance (see Job.created_by). Stored as marker attributes so
    /// ownership survives serialize/parse round-trips.
    created_by: ?[]const u8 = null,
    created_at: ?i64 = null,
    last_modified_by: ?[]const u8 = null,
    last_modified_at: ?i64 = null,
};

pub fn parseMarker(a: std.mem.Allocator, line: []const u8) ?Marker {
    if (!std.mem.startsWith(u8, line, MARKER)) return null;
    var id: []const u8 = "";
    var enabled = true;
    var once = false;
    var capture = false;
    var run_id: ?[]const u8 = null;
    var timeout_secs: ?u32 = null;
    var wrapper_bin: ?[]const u8 = null;
    var created_by: ?[]const u8 = null;
    var created_at: ?i64 = null;
    var last_modified_by: ?[]const u8 = null;
    var last_modified_at: ?i64 = null;
    var it = std.mem.tokenizeAny(u8, line[MARKER.len..], " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "id=")) id = a.dupe(u8, tok[3..]) catch tok[3..];
        if (std.mem.startsWith(u8, tok, "enabled=")) enabled = std.mem.eql(u8, tok[8..], "1");
        if (std.mem.startsWith(u8, tok, "once=")) once = std.mem.eql(u8, tok[5..], "1");
        if (std.mem.startsWith(u8, tok, "capture=")) capture = std.mem.eql(u8, tok[8..], "1");
        if (std.mem.startsWith(u8, tok, "run_id=")) run_id = a.dupe(u8, tok[7..]) catch tok[7..];
        if (std.mem.startsWith(u8, tok, "timeout_secs=")) timeout_secs = std.fmt.parseInt(u32, tok[13..], 10) catch null;
        if (std.mem.startsWith(u8, tok, "wrapper_bin=")) wrapper_bin = a.dupe(u8, tok[12..]) catch tok[12..];
        if (std.mem.startsWith(u8, tok, "created_by=")) created_by = a.dupe(u8, tok[11..]) catch tok[11..];
        if (std.mem.startsWith(u8, tok, "created_at=")) created_at = std.fmt.parseInt(i64, tok[11..], 10) catch null;
        if (std.mem.startsWith(u8, tok, "last_modified_by=")) last_modified_by = a.dupe(u8, tok[17..]) catch tok[17..];
        if (std.mem.startsWith(u8, tok, "last_modified_at=")) last_modified_at = std.fmt.parseInt(i64, tok[17..], 10) catch null;
    }
    if (id.len == 0) return null;
    return .{
        .id = id,
        .enabled = enabled,
        .once = once,
        .capture = capture,
        .run_id = run_id,
        .timeout_secs = timeout_secs,
        .wrapper_bin = wrapper_bin,
        .created_by = created_by,
        .created_at = created_at,
        .last_modified_by = last_modified_by,
        .last_modified_at = last_modified_at,
    };
}

/// Sentinel inside a wrapped cron payload that separates the wrapper
/// flags from the inner shell command. Anything matching " -- /bin/sh -c "
/// is the user's command, single-quoted for shell-safety.
const WRAPPER_INNER_SENTINEL = " -- /bin/sh -c ";

/// Cron treats `%` in the command portion as a literal newline (man 5
/// crontab), splitting the command and turning everything after into
/// stdin. The only way to pass a literal `%` to the shell is to write
/// `\%` in the crontab — cron strips the `\` before invoking sh.
///
/// This is invisible to single-quote shell quoting (which doesn't escape
/// `%`), so a perfectly valid shell-quoted command like `'$(date +%H)'`
/// gets eaten by cron before sh ever sees it. We post-escape after
/// shellQuote so the on-disk crontab carries `\%` and round-trips back
/// to `%` via cronUnescape on parse.
fn cronEscape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var count: usize = 0;
    for (s) |ch| if (ch == '%') {
        count += 1;
    };
    if (count == 0) return a.dupe(u8, s);
    var out = try a.alloc(u8, s.len + count);
    var j: usize = 0;
    for (s) |ch| {
        if (ch == '%') {
            out[j] = '\\';
            out[j + 1] = '%';
            j += 2;
        } else {
            out[j] = ch;
            j += 1;
        }
    }
    return out;
}

/// Inverse of cronEscape: turn `\%` back into `%`. Only `\%` is unescaped
/// — other backslash sequences (`\\`, `\n`, etc.) are left alone, since
/// cron's escaping rule applies only to `%`. Lone `\` followed by anything
/// other than `%` stays literal.
fn cronUnescape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, s, "\\%") == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (i + 1 < s.len and s[i] == '\\' and s[i + 1] == '%') {
            try out.append(a, '%');
            i += 1; // skip the %; outer loop's i+=1 skips the \
        } else {
            try out.append(a, s[i]);
        }
    }
    return out.toOwnedSlice(a);
}

/// Synthesize a wrapped cron payload from a Job's marker attributes.
/// Returns `error.NoWrapperBin` if the job is marked wrapped but its
/// wrapper_bin is null — should never happen for jobs written by looper,
/// but guards a malformed hand-edit.
///
/// Shape:
///   <wrapper_bin> _exec --source-id=<id> [--once] [--run-id=<r>]
///                       [--timeout-secs=<n>] -- /bin/sh -c '<inner>'
///
/// where `<inner>` is the shell-quoted form of `j.command`. cron will
/// pass the whole line to /bin/sh, which exec's looper, which then
/// `/bin/sh -c`'s the user's command — preserving cron-equivalent
/// shell semantics (pipes, redirects, env-var expansion).
pub fn wrapCommand(a: std.mem.Allocator, j: Job) ![]u8 {
    const wb = j.wrapper_bin orelse return error.NoWrapperBin;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, wb);
    try out.appendSlice(a, " _exec --source-id=");
    try out.appendSlice(a, j.id);
    if (j.once) try out.appendSlice(a, " --once");
    if (j.run_id) |rid| {
        try out.appendSlice(a, " --run-id=");
        try out.appendSlice(a, rid);
    }
    if (j.timeout_secs) |t| {
        const s = try std.fmt.allocPrint(a, " --timeout-secs={d}", .{t});
        try out.appendSlice(a, s);
    }
    // Carry ownership forward to the cron-fired _exec call. Without
    // this, `runs ls --owner` is dead for the cron path because the
    // resulting run record has no `created_by`. Principal values are
    // validated whitespace-free at CLI ingress (see cli.isValidPrincipal),
    // so a bare `--owner=<v>` token round-trips through cron's shell
    // tokenizer safely.
    if (j.created_by) |cb| {
        try out.appendSlice(a, " --owner=");
        try out.appendSlice(a, cb);
    }
    try out.appendSlice(a, WRAPPER_INNER_SENTINEL);
    const quoted = posix.shellQuote(a, j.command);
    try out.appendSlice(a, quoted);
    const payload = try out.toOwnedSlice(a);
    // Final cron-level escape on the whole payload. The wrapper portion
    // (path + flags) rarely contains `%`, but escaping universally is
    // cheap and keeps the rule "no raw `%` survives into the crontab".
    return cronEscape(a, payload);
}

/// Inverse of `wrapCommand`: extract the inner command from a wrapped
/// cron payload. Returns null on malformed input — caller falls back to
/// displaying the raw payload, which is at least informative even if
/// ugly. The sentinel-based split tolerates flag variation; only the
/// final " -- /bin/sh -c '...'" tail has to match.
///
/// Reverses cronEscape's `%` → `\%` substitution AFTER shellUnquote so
/// the user's command surfaces in its original form.
pub fn tryUnwrapInner(a: std.mem.Allocator, payload: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, payload, WRAPPER_INNER_SENTINEL) orelse return null;
    const after = payload[start + WRAPPER_INNER_SENTINEL.len ..];
    const quoted_inner = posix.shellUnquote(a, after) orelse return null;
    return cronUnescape(a, quoted_inner) catch null;
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
    if (m.wrapper_bin) |wb| ctx_mod.aw(a, &out, " wrapper_bin={s}", .{wb});
    if (m.created_by) |cb| ctx_mod.aw(a, &out, " created_by={s}", .{cb});
    if (m.created_at) |ca| ctx_mod.aw(a, &out, " created_at={d}", .{ca});
    if (m.last_modified_by) |lb| ctx_mod.aw(a, &out, " last_modified_by={s}", .{lb});
    if (m.last_modified_at) |la| ctx_mod.aw(a, &out, " last_modified_at={d}", .{la});
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
                // For wrapped jobs (capture or once), the cron payload is
                // the `_exec` invocation; strip the wrapper so Job.command
                // is what the user typed. If the unwrap fails (malformed
                // wrapper, hand-edit, format drift), keep the full payload
                // — degraded display beats silent data loss.
                const cmd_inner: []const u8 = blk: {
                    if (pm.capture or pm.once) {
                        if (tryUnwrapInner(a, sc.cmd)) |inner| break :blk inner;
                    }
                    break :blk try a.dupe(u8, sc.cmd);
                };
                try ct.items.append(a, .{ .job = .{
                    .id = pm.id,
                    .enabled = pm.enabled,
                    .schedule = try a.dupe(u8, sc.sched),
                    .command = cmd_inner,
                    .once = pm.once,
                    .capture = pm.capture,
                    .run_id = pm.run_id,
                    .timeout_secs = pm.timeout_secs,
                    .wrapper_bin = pm.wrapper_bin,
                    .created_by = pm.created_by,
                    .created_at = pm.created_at,
                    .last_modified_by = pm.last_modified_by,
                    .last_modified_at = pm.last_modified_at,
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
                    .wrapper_bin = j.wrapper_bin,
                    .created_by = j.created_by,
                    .created_at = j.created_at,
                    .last_modified_by = j.last_modified_by,
                    .last_modified_at = j.last_modified_at,
                });
                try out.appendSlice(a, marker_line);
                try out.append(a, '\n');
                // Wrapped jobs serialize their cron payload from the
                // marker attrs; plain jobs emit Job.command verbatim.
                // Wrapper synthesis failure (no wrapper_bin) falls back
                // to verbatim emission so a malformed in-memory Job
                // doesn't lose data on write.
                const payload: []const u8 = blk: {
                    if ((j.once or j.capture) and j.wrapper_bin != null) {
                        break :blk wrapCommand(a, j) catch j.command;
                    }
                    break :blk j.command;
                };
                if (j.enabled) ctx_mod.aw(a, &out, "{s} {s}\n", .{ j.schedule, payload }) else ctx_mod.aw(a, &out, "# {s} {s}\n", .{ j.schedule, payload });
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

test "wrapCommand synthesizes the canonical wrapper invocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrapCommand(a, .{
        .id = "daily-backup",
        .enabled = true,
        .schedule = "0 3 * * *",
        .command = "/usr/local/bin/backup.sh",
        .capture = true,
        .wrapper_bin = "/usr/local/bin/looper",
    });
    try testing.expectEqualStrings(
        "/usr/local/bin/looper _exec --source-id=daily-backup -- /bin/sh -c '/usr/local/bin/backup.sh'",
        out,
    );
}

test "wrapCommand emits --once + --run-id + --timeout-secs when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrapCommand(a, .{
        .id = "test-oneshot",
        .enabled = true,
        .schedule = "57 14 23 5 *",
        .command = "echo hi",
        .once = true,
        .capture = true,
        .run_id = "abc123",
        .timeout_secs = 300,
        .wrapper_bin = "/usr/local/bin/looper",
    });
    try testing.expectEqualStrings(
        "/usr/local/bin/looper _exec --source-id=test-oneshot --once --run-id=abc123 --timeout-secs=300 -- /bin/sh -c 'echo hi'",
        out,
    );
}

test "wrapCommand shell-quotes commands with embedded single quotes" {
    // The classic stress test: user's command contains apostrophes.
    // wrapCommand's job is to make sure those survive the trip through
    // cron's outer shell.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrapCommand(a, .{
        .id = "msg",
        .enabled = true,
        .schedule = "0 9 * * *",
        .command = "echo it's tuesday",
        .capture = true,
        .wrapper_bin = "/usr/local/bin/looper",
    });
    try testing.expectEqualStrings(
        "/usr/local/bin/looper _exec --source-id=msg -- /bin/sh -c 'echo it'\\''s tuesday'",
        out,
    );
}

test "wrapCommand escapes % to \\% (cron's newline trigger)" {
    // Cron treats unescaped `%` in the command portion as a literal
    // newline (man 5 crontab), which mangles any command containing
    // strftime format strings, URL-encoded args, or printf %d.
    // wrapCommand must escape so the on-disk crontab has \%.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrapCommand(a, .{
        .id = "tz-stamp",
        .enabled = true,
        .schedule = "0 9 * * *",
        .command = "echo $(date +%H:%M:%S)",
        .capture = true,
        .wrapper_bin = "/usr/local/bin/looper",
    });
    try testing.expectEqualStrings(
        "/usr/local/bin/looper _exec --source-id=tz-stamp -- /bin/sh -c 'echo $(date +\\%H:\\%M:\\%S)'",
        out,
    );
}

test "tryUnwrapInner reverses % escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wrapped = "/usr/local/bin/looper _exec --source-id=x -- /bin/sh -c 'echo $(date +\\%H:\\%M:\\%S)'";
    const inner = tryUnwrapInner(a, wrapped).?;
    try testing.expectEqualStrings("echo $(date +%H:%M:%S)", inner);
}

test "wrapCommand + tryUnwrapInner round-trip with % chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const originals = [_][]const u8{
        "echo $(date +%H:%M:%S)",
        "printf '%d items\\n' 42",
        "echo 100%% done",
        "wget 'https://example.com/path%20with%20spaces'",
    };
    for (originals) |inner| {
        const wrapped = try wrapCommand(a, .{
            .id = "pct",
            .enabled = true,
            .schedule = "@daily",
            .command = inner,
            .capture = true,
            .wrapper_bin = "/usr/local/bin/looper",
        });
        const back = tryUnwrapInner(a, wrapped).?;
        try testing.expectEqualStrings(inner, back);
    }
}

test "parseMarker round-trips the four provenance fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = parseMarker(
        arena.allocator(),
        "#looper# id=x enabled=1 created_by=agent-a created_at=1700000000 last_modified_by=agent-b last_modified_at=1700000500",
    ).?;
    try testing.expectEqualStrings("agent-a", m.created_by.?);
    try testing.expectEqual(@as(?i64, 1700000000), m.created_at);
    try testing.expectEqualStrings("agent-b", m.last_modified_by.?);
    try testing.expectEqual(@as(?i64, 1700000500), m.last_modified_at);
}

test "serializeMarker omits provenance fields when unset (legacy byte-stability)" {
    // Forward-compat: a job without provenance must serialize to the
    // exact bytes a pre-provenance looper would have written. Otherwise
    // every existing crontab on every host changes shape on first read,
    // even if no agent has touched the job.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try serializeMarker(arena.allocator(), .{ .id = "legacy", .enabled = true });
    try testing.expectEqualStrings("#looper# id=legacy enabled=1", out);
}

test "serializeMarker emits provenance fields when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try serializeMarker(arena.allocator(), .{
        .id = "x",
        .enabled = true,
        .created_by = "agent-a",
        .created_at = 1700000000,
        .last_modified_by = "agent-b",
        .last_modified_at = 1700000500,
    });
    try testing.expectEqualStrings(
        "#looper# id=x enabled=1 created_by=agent-a created_at=1700000000 last_modified_by=agent-b last_modified_at=1700000500",
        out,
    );
}

test "wrapCommand emits --owner=<v> when created_by is set" {
    // Carries provenance forward into the cron-fired _exec call so
    // `runs ls --owner` works for cron-fired runs (HIGH#2 fix).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrapCommand(a, .{
        .id = "rec",
        .enabled = true,
        .schedule = "@daily",
        .command = "echo hi",
        .capture = true,
        .wrapper_bin = "/usr/local/bin/looper",
        .created_by = "agent-a",
    });
    try testing.expect(std.mem.indexOf(u8, out, " --owner=agent-a") != null);
    // Sanity-check positioning: --owner must precede the inner sentinel
    // so cron's shell tokenizer treats it as a wrapper flag.
    const owner_pos = std.mem.indexOf(u8, out, "--owner=agent-a").?;
    const sentinel_pos = std.mem.indexOf(u8, out, " -- /bin/sh -c ").?;
    try testing.expect(owner_pos < sentinel_pos);
}

test "wrapCommand omits --owner when created_by is null (regression guard)" {
    // Existing roundtrip tests assume bare wrapper lines for jobs
    // without provenance — pin the no-emit branch.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrapCommand(a, .{
        .id = "rec",
        .enabled = true,
        .schedule = "@daily",
        .command = "echo hi",
        .capture = true,
        .wrapper_bin = "/usr/local/bin/looper",
    });
    try testing.expect(std.mem.indexOf(u8, out, "--owner=") == null);
}

test "wrapCommand fails when wrapper_bin is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = wrapCommand(a, .{
        .id = "x",
        .enabled = true,
        .schedule = "0 3 * * *",
        .command = "/bin/true",
        .capture = true,
    });
    try testing.expectError(error.NoWrapperBin, result);
}

test "tryUnwrapInner extracts the inner from a wrapped payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = "/usr/local/bin/looper _exec --source-id=foo -- /bin/sh -c '/usr/local/bin/backup.sh'";
    const inner = tryUnwrapInner(a, payload).?;
    try testing.expectEqualStrings("/usr/local/bin/backup.sh", inner);
}

test "tryUnwrapInner returns null for unwrapped payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?[]const u8, null), tryUnwrapInner(a, "/bin/echo hi"));
    try testing.expectEqual(@as(?[]const u8, null), tryUnwrapInner(a, "looper _exec --source-id=x /bin/echo hi"));
}

test "wrapCommand + tryUnwrapInner are inverses across awkward inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inputs = [_][]const u8{
        "/bin/true",
        "echo hi",
        "it's me",
        "echo $HOME",
        "a 'quoted' b",
        "rsync -av /src/ user@host:/dst/",
    };
    for (inputs) |inner| {
        const wrapped = try wrapCommand(a, .{
            .id = "rt",
            .enabled = true,
            .schedule = "@daily",
            .command = inner,
            .capture = true,
            .wrapper_bin = "/usr/local/bin/looper",
        });
        const back = tryUnwrapInner(a, wrapped).?;
        try testing.expectEqualStrings(inner, back);
    }
}

test "parseCrontab unwraps Job.command for wrapped marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=daily-backup enabled=1 capture=1 wrapper_bin=/usr/local/bin/looper
        \\0 3 * * * /usr/local/bin/looper _exec --source-id=daily-backup -- /bin/sh -c '/usr/local/bin/backup.sh'
        \\
    ;
    const ct = try parseCrontab(a, input);
    switch (ct.items.items[0]) {
        .job => |j| {
            // User-visible Job.command is the inner, not the wrapper.
            try testing.expectEqualStrings("/usr/local/bin/backup.sh", j.command);
            try testing.expect(j.capture);
            try testing.expectEqualStrings("/usr/local/bin/looper", j.wrapper_bin.?);
        },
        else => return error.UnexpectedItem,
    }
}

test "serialize roundtrip wrapped job preserves bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=daily-backup enabled=1 capture=1 wrapper_bin=/usr/local/bin/looper
        \\0 3 * * * /usr/local/bin/looper _exec --source-id=daily-backup -- /bin/sh -c '/usr/local/bin/backup.sh'
        \\
    ;
    var ct = try parseCrontab(a, input);
    const out = try serialize(a, &ct);
    try testing.expectEqualStrings(input, out);
}

test "serialize roundtrip wrapped one-shot with all attrs preserves bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\#looper# id=test-fire enabled=1 once=1 capture=1 run_id=rid-7 timeout_secs=300 wrapper_bin=/usr/local/bin/looper
        \\57 14 23 5 * /usr/local/bin/looper _exec --source-id=test-fire --once --run-id=rid-7 --timeout-secs=300 -- /bin/sh -c 'echo hi'
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
