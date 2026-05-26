//! Minimal TOML-ish parser for declarative job specs (v0.2 #2). The grammar
//! we actually consume is a small subset of TOML:
//!
//!   [[job]]
//!   id = "spec-a"
//!   schedule = "0 3 * * *"
//!   command = "/usr/bin/true"
//!
//! That's the entire surface — array-of-tables headers, three known keys per
//! table, and double-quoted string values. Comments (`#`) and blank lines are
//! ignored. We intentionally do NOT vendor a real TOML implementation: the
//! spec format is a contract we own, every supported field is one we wrote,
//! and a 100-line hand-rolled parser is easier to audit than a third-party
//! library at this scope. If the spec grows ints/arrays/datetimes later,
//! that's the moment to swap in a real parser.
//!
//! Pure module — no I/O. Callers read the file and pass bytes.

const std = @import("std");

pub const SpecJob = struct {
    id: []const u8,
    schedule: []const u8,
    command: []const u8,
};

pub const SpecParseError = error{
    UnexpectedKeyOutsideTable,
    UnknownTable,
    UnknownKey,
    MalformedAssignment,
    UnterminatedString,
    MissingRequiredField,
    DuplicateId,
    OutOfMemory,
};

pub const Spec = struct {
    jobs: []SpecJob,
};

/// Parse a spec source. Returns Spec.jobs allocated via `a`; ownership
/// transfers to the caller. On any error, returns the typed SpecParseError
/// and leaves a human-readable explanation in `diag` (a pointer to a
/// `?[]const u8`) — the caller surfaces it in the CLI diagnostic.
pub fn parse(a: std.mem.Allocator, source: []const u8, diag: *?[]const u8) SpecParseError!Spec {
    var jobs: std.ArrayList(SpecJob) = .empty;
    var current: ?SpecJob = null;
    var have_id = false;
    var have_sched = false;
    var have_cmd = false;
    var line_no: usize = 0;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "[[")) {
            if (!std.mem.endsWith(u8, line, "]]")) {
                diag.* = try std.fmt.allocPrint(a, "line {d}: malformed table header (expected `[[job]]`)", .{line_no});
                return SpecParseError.MalformedAssignment;
            }
            const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
            if (!std.mem.eql(u8, name, "job")) {
                diag.* = try std.fmt.allocPrint(a, "line {d}: unknown table `[[{s}]]` (only `[[job]]` is supported)", .{ line_no, name });
                return SpecParseError.UnknownTable;
            }
            try flushJob(a, &jobs, &current, have_id, have_sched, have_cmd, diag, line_no);
            current = .{ .id = "", .schedule = "", .command = "" };
            have_id = false;
            have_sched = false;
            have_cmd = false;
            continue;
        }

        if (line[0] == '[') {
            diag.* = try std.fmt.allocPrint(a, "line {d}: only `[[job]]` arrays-of-tables are supported", .{line_no});
            return SpecParseError.UnknownTable;
        }

        // key = "value"
        if (current == null) {
            diag.* = try std.fmt.allocPrint(a, "line {d}: assignment before any `[[job]]` header", .{line_no});
            return SpecParseError.UnexpectedKeyOutsideTable;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            diag.* = try std.fmt.allocPrint(a, "line {d}: expected `key = \"value\"`", .{line_no});
            return SpecParseError.MalformedAssignment;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value = parseString(a, value_raw) catch {
            diag.* = try std.fmt.allocPrint(a, "line {d}: value must be a double-quoted string", .{line_no});
            return SpecParseError.UnterminatedString;
        };

        if (std.mem.eql(u8, key, "id")) {
            current.?.id = value;
            have_id = true;
        } else if (std.mem.eql(u8, key, "schedule")) {
            current.?.schedule = value;
            have_sched = true;
        } else if (std.mem.eql(u8, key, "command")) {
            current.?.command = value;
            have_cmd = true;
        } else {
            diag.* = try std.fmt.allocPrint(a, "line {d}: unknown key `{s}` (allowed: id, schedule, command)", .{ line_no, key });
            return SpecParseError.UnknownKey;
        }
    }

    try flushJob(a, &jobs, &current, have_id, have_sched, have_cmd, diag, line_no);

    // Reject duplicate ids: the convergent model needs id to be a primary key,
    // and silent "last write wins" would mask spec authoring mistakes.
    var i: usize = 0;
    while (i < jobs.items.len) : (i += 1) {
        var j = i + 1;
        while (j < jobs.items.len) : (j += 1) {
            if (std.mem.eql(u8, jobs.items[i].id, jobs.items[j].id)) {
                diag.* = try std.fmt.allocPrint(a, "duplicate `id = \"{s}\"` in spec", .{jobs.items[i].id});
                return SpecParseError.DuplicateId;
            }
        }
    }

    return .{ .jobs = try jobs.toOwnedSlice(a) };
}

fn flushJob(
    a: std.mem.Allocator,
    jobs: *std.ArrayList(SpecJob),
    current: *?SpecJob,
    have_id: bool,
    have_sched: bool,
    have_cmd: bool,
    diag: *?[]const u8,
    line_no: usize,
) SpecParseError!void {
    const j = current.* orelse return;
    if (!have_id or !have_sched or !have_cmd) {
        diag.* = try std.fmt.allocPrint(a, "line {d}: `[[job]]` missing required field(s) (need id, schedule, command)", .{line_no});
        return SpecParseError.MissingRequiredField;
    }
    try jobs.append(a, j);
    current.* = null;
}

fn stripComment(line: []const u8) []const u8 {
    // Comments inside quoted values aren't supported by our minimal parser;
    // we strip from the first `#` we see, on the assumption that real specs
    // don't embed `#` in cron schedules or commands. If that bites later, the
    // fix is a real TOML parser, not a clever comment-stripper.
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return std.mem.trimEnd(u8, line[0..hash], " \t");
}

fn parseString(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.UnterminatedString;
    const inner = raw[1 .. raw.len - 1];
    // No escape sequences in v0.2 — keep the parser dumb. If someone needs
    // a literal `"` inside a command, the spec format isn't expressive
    // enough yet; the diagnostic surfaces as "unterminated string" because
    // the second `"` ends the value early.
    return a.dupe(u8, inner);
}

const testing = std.testing;

test "parse single job" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    const spec = try parse(arena.allocator(),
        \\[[job]]
        \\id = "spec-a"
        \\schedule = "0 3 * * *"
        \\command = "/usr/bin/true"
        \\
    , &diag);
    try testing.expectEqual(@as(usize, 1), spec.jobs.len);
    try testing.expectEqualStrings("spec-a", spec.jobs[0].id);
    try testing.expectEqualStrings("0 3 * * *", spec.jobs[0].schedule);
    try testing.expectEqualStrings("/usr/bin/true", spec.jobs[0].command);
}

test "parse two jobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    const spec = try parse(arena.allocator(),
        \\[[job]]
        \\id = "a"
        \\schedule = "0 3 * * *"
        \\command = "/bin/true"
        \\
        \\[[job]]
        \\id = "b"
        \\schedule = "@daily"
        \\command = "/bin/false"
    , &diag);
    try testing.expectEqual(@as(usize, 2), spec.jobs.len);
    try testing.expectEqualStrings("b", spec.jobs[1].id);
    try testing.expectEqualStrings("@daily", spec.jobs[1].schedule);
}

test "parse ignores blank lines and comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    const spec = try parse(arena.allocator(),
        \\# a top-level comment
        \\
        \\[[job]]  # inline comment
        \\id = "a"
        \\schedule = "@daily"
        \\command = "/bin/true"
    , &diag);
    try testing.expectEqual(@as(usize, 1), spec.jobs.len);
}

test "parse rejects assignment before table header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    try testing.expectError(SpecParseError.UnexpectedKeyOutsideTable, parse(
        arena.allocator(),
        \\id = "x"
        \\
    ,
        &diag,
    ));
    try testing.expect(diag != null);
}

test "parse rejects unknown table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    try testing.expectError(SpecParseError.UnknownTable, parse(
        arena.allocator(),
        \\[[host]]
        \\id = "x"
        \\
    ,
        &diag,
    ));
}

test "parse rejects unknown key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    try testing.expectError(SpecParseError.UnknownKey, parse(
        arena.allocator(),
        \\[[job]]
        \\id = "x"
        \\schedule = "@daily"
        \\command = "/bin/true"
        \\frob = "nicate"
        \\
    ,
        &diag,
    ));
}

test "parse rejects job missing required field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    try testing.expectError(SpecParseError.MissingRequiredField, parse(
        arena.allocator(),
        \\[[job]]
        \\id = "x"
        \\schedule = "@daily"
        \\
    ,
        &diag,
    ));
}

test "parse rejects duplicate id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    try testing.expectError(SpecParseError.DuplicateId, parse(
        arena.allocator(),
        \\[[job]]
        \\id = "x"
        \\schedule = "@daily"
        \\command = "/bin/true"
        \\
        \\[[job]]
        \\id = "x"
        \\schedule = "@hourly"
        \\command = "/bin/false"
    ,
        &diag,
    ));
}

test "parse rejects unquoted value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    try testing.expectError(SpecParseError.UnterminatedString, parse(
        arena.allocator(),
        \\[[job]]
        \\id = x
        \\schedule = "@daily"
        \\command = "/bin/true"
    ,
        &diag,
    ));
}
