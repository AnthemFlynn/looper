//! `agenda` — chronological "what fires next" view across one or many
//! targets. Owns its own target iteration (like `doctor`) because the
//! output is a single merged list sorted by absolute UTC, not the
//! per-target shape every other read verb produces.
//!
//! Includes foreign (unmanaged) jobs by default: cron will run them
//! whether looper acknowledges them or not, so an agent planning when
//! to schedule new work needs to see all upcoming activity. Foreign
//! lines whose schedule doesn't parse are silently skipped.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const sched_mod = @import("../cron/schedule.zig");
const humanize = @import("../cron/humanize.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");
const tz_mod = @import("../tz.zig");
const core = @import("core.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;
const TzInfo = tz_mod.TzInfo;

pub const SCHEMA_VERSION: u32 = 1;

pub const AgendaOpts = struct {
    /// `-n N`: maximum events returned after sort+cutoff. Default 20.
    limit: usize = 20,
    /// `--within <duration>`: only events firing within this many seconds
    /// from now. Null = no cutoff (return up to `limit` events).
    within_secs: ?i64 = null,
    /// `--owner <principal>`: filter to managed jobs whose `created_by`
    /// matches. Foreign jobs (no marker → no provenance) never match a
    /// non-null owner filter.
    owner: ?[]const u8 = null,
};

const Event = struct {
    epoch: i64,
    target_label: []const u8,
    id: []const u8,
    schedule: []const u8,
    command: []const u8,
    foreign: bool,
    enabled: bool,
    created_by: ?[]const u8,
    tz_abbrev: []const u8,
    tz_offset_secs: i32,
    tz_source: tz_mod.Source,
};

/// Owns the per-target read loop. Per-target read failures are reported
/// but do not abort the agenda — drift on one host shouldn't blind the
/// caller to upcoming fires on the others.
pub fn cmdAgenda(
    ctx: *Ctx,
    targets: []const Target,
    opts: AgendaOpts,
    no_target_tz: bool,
) !void {
    var events: std.ArrayList(Event) = .empty;
    const now = posix.nowEpoch();
    const cutoff: ?i64 = if (opts.within_secs) |w| now + w else null;

    for (targets) |t| {
        const rr = target_mod.readCrontabAndTz(ctx.a, t, !no_target_tz) catch |e| {
            posix.eprint("looper: cannot read crontab on {s}: {s}\n", .{ t.label(ctx.a), @errorName(e) });
            ctx.fail(1);
            continue;
        };
        const content = rr.content;
        var tz: tz_mod.TzInfo = rr.tz orelse tz_mod.controllerTz(ctx.a);
        if (rr.tz == null and t.kind == .remote) tz.source = .controller_fallback;
        const ct = try model.parseCrontab(ctx.a, content);
        const target_label = t.label(ctx.a);
        var foreign_n: usize = 0;
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                // Owner filter: foreign jobs lack provenance, so any
                // non-null owner filter excludes them entirely.
                if (opts.owner != null and j.foreign) continue;
                if (opts.owner) |want| {
                    const got = j.created_by orelse continue;
                    if (!std.mem.eql(u8, got, want)) continue;
                }
                // Disabled managed jobs never fire — drop them from the
                // agenda. Foreign lines have no enabled flag (always true
                // from looper's perspective).
                if (!j.foreign and !j.enabled) continue;
                const sched = sched_mod.parseSchedule(j.schedule) catch continue;
                const nr = core.nextFor(sched, now, tz) orelse continue;
                if (cutoff) |co| if (nr > co) continue;
                const id_label = if (j.foreign) blk: {
                    foreign_n += 1;
                    break :blk std.fmt.allocPrint(ctx.a, "f{d}", .{foreign_n}) catch "f?";
                } else j.id;
                try events.append(ctx.a, .{
                    .epoch = nr,
                    .target_label = target_label,
                    .id = id_label,
                    .schedule = j.schedule,
                    .command = j.command,
                    .foreign = j.foreign,
                    .enabled = j.enabled,
                    .created_by = j.created_by,
                    .tz_abbrev = tz.abbrev,
                    .tz_offset_secs = tz.offset_secs,
                    .tz_source = tz.source,
                });
            },
            else => {},
        };
    }

    // Sort ascending by epoch; deterministic tie-break by target then id.
    std.mem.sort(Event, events.items, {}, lessThan);
    const slice = if (events.items.len > opts.limit) events.items[0..opts.limit] else events.items;

    if (ctx.json) {
        ctx.emit("{{\"schema_version\":{d},\"events\":[", .{SCHEMA_VERSION});
        for (slice, 0..) |e, i| {
            if (i > 0) ctx.emit(",", .{});
            const tzi: TzInfo = .{ .abbrev = e.tz_abbrev, .offset_secs = e.tz_offset_secs, .source = e.tz_source };
            const nh = humanize.fmtWhenIn(ctx.a, e.epoch, tzi);
            ctx.emit(
                "{{\"epoch\":{d},\"next_human\":\"{s}\",\"target\":\"{s}\"," ++
                    "\"id\":\"{s}\",\"foreign\":{s},\"enabled\":{s}," ++
                    "\"schedule\":\"{s}\",\"command\":\"{s}\"," ++
                    "\"tz\":\"{s}\",\"tz_offset_secs\":{d},\"tz_source\":\"{s}\"",
                .{
                    e.epoch,                              display.jsonEsc(ctx.a, nh),       display.jsonEsc(ctx.a, e.target_label),
                    display.jsonEsc(ctx.a, e.id),         if (e.foreign) "true" else "false", if (e.enabled) "true" else "false",
                    display.jsonEsc(ctx.a, e.schedule),   display.jsonEsc(ctx.a, e.command),
                    display.jsonEsc(ctx.a, e.tz_abbrev), e.tz_offset_secs,                  tz_mod.sourceStr(e.tz_source),
                },
            );
            if (e.created_by) |v| ctx.emit(",\"created_by\":\"{s}\"", .{display.jsonEsc(ctx.a, v)}) else ctx.emit(",\"created_by\":null", .{});
            ctx.emit("}}", .{});
        }
        ctx.emit("]}}\n", .{});
        return;
    }

    if (slice.len == 0) {
        ctx.emit("{s}no upcoming events{s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET) });
        return;
    }

    const w = display.termWidth();
    const when_w: usize = 40;
    const target_w: usize = 14;
    const id_w: usize = 14;
    const fixed = when_w + target_w + id_w + 4;
    const cmd_w = if (w > fixed + 12) w - fixed else 24;
    ctx.emit("{s}{s}{s}{s}{s}{s}\n", .{
        ctx.k(colors.BOLD),
        display.padTo(ctx.a, "WHEN", when_w),
        display.padTo(ctx.a, "TARGET", target_w),
        display.padTo(ctx.a, "ID", id_w),
        "COMMAND",
        ctx.k(colors.RESET),
    });
    for (slice) |e| {
        const tzi: TzInfo = .{ .abbrev = e.tz_abbrev, .offset_secs = e.tz_offset_secs, .source = e.tz_source };
        const when = humanize.fmtWhenIn(ctx.a, e.epoch, tzi);
        const idcolor = if (e.foreign) ctx.k(colors.YELLOW) else ctx.k(colors.CYAN);
        const id_disp = if (e.foreign)
            (std.fmt.allocPrint(ctx.a, "{s} [foreign]", .{e.id}) catch e.id)
        else
            e.id;
        ctx.emit("{s}{s}{s}{s} {s}{s}{s} {s}\n", .{
            display.padTo(ctx.a, when, when_w),
            idcolor, display.padTo(ctx.a, e.target_label, target_w), ctx.k(colors.RESET),
            idcolor, display.padTo(ctx.a, id_disp, id_w),            ctx.k(colors.RESET),
            display.truncEllipsis(ctx.a, e.command, cmd_w),
        });
    }
}

fn lessThan(_: void, a: Event, b: Event) bool {
    if (a.epoch != b.epoch) return a.epoch < b.epoch;
    const tc = std.mem.order(u8, a.target_label, b.target_label);
    if (tc != .eq) return tc == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Parse a duration string for `--within`. Accepts:
///   - bare integer → seconds
///   - `<n>s` → seconds
///   - `<n>m` → minutes
///   - `<n>h` → hours
///   - `<n>d` → days
///   - `<n>w` → weeks
/// Returns null on parse failure (unknown suffix, non-integer, overflow).
pub fn parseDuration(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var end: usize = s.len;
    var mult: i64 = 1;
    const last = s[s.len - 1];
    if (!std.ascii.isDigit(last)) {
        end = s.len - 1;
        mult = switch (last) {
            's', 'S' => 1,
            'm', 'M' => 60,
            'h', 'H' => 60 * 60,
            'd', 'D' => 24 * 60 * 60,
            'w', 'W' => 7 * 24 * 60 * 60,
            else => return null,
        };
    }
    if (end == 0) return null;
    const n = std.fmt.parseInt(i64, s[0..end], 10) catch return null;
    return std.math.mul(i64, n, mult) catch null;
}

const testing = std.testing;

test "parseDuration: bare integer is seconds" {
    try testing.expectEqual(@as(?i64, 30), parseDuration("30"));
    try testing.expectEqual(@as(?i64, 0), parseDuration("0"));
}

test "parseDuration: unit suffixes" {
    try testing.expectEqual(@as(?i64, 60), parseDuration("1m"));
    try testing.expectEqual(@as(?i64, 60 * 60), parseDuration("1h"));
    try testing.expectEqual(@as(?i64, 24 * 60 * 60), parseDuration("1d"));
    try testing.expectEqual(@as(?i64, 7 * 24 * 60 * 60), parseDuration("1w"));
    try testing.expectEqual(@as(?i64, 12 * 60 * 60), parseDuration("12h"));
    // case-insensitive
    try testing.expectEqual(@as(?i64, 60 * 60), parseDuration("1H"));
}

test "parseDuration: rejects unknown suffix" {
    try testing.expectEqual(@as(?i64, null), parseDuration("1y"));
    try testing.expectEqual(@as(?i64, null), parseDuration("abc"));
    try testing.expectEqual(@as(?i64, null), parseDuration(""));
    try testing.expectEqual(@as(?i64, null), parseDuration("h"));
}

test "lessThan: epoch is primary key" {
    const a: Event = .{
        .epoch = 100,                 .target_label = "z", .id = "z",
        .schedule = "",               .command = "",       .foreign = false,
        .enabled = true,              .created_by = null,  .tz_abbrev = "UTC",
        .tz_offset_secs = 0,          .tz_source = .controller_local,
    };
    const b: Event = .{
        .epoch = 200,                 .target_label = "a", .id = "a",
        .schedule = "",               .command = "",       .foreign = false,
        .enabled = true,              .created_by = null,  .tz_abbrev = "UTC",
        .tz_offset_secs = 0,          .tz_source = .controller_local,
    };
    try testing.expect(lessThan({}, a, b));
    try testing.expect(!lessThan({}, b, a));
}

test "lessThan: tiebreak by target then id" {
    const a: Event = .{
        .epoch = 100,                 .target_label = "host-a", .id = "z",
        .schedule = "",               .command = "",            .foreign = false,
        .enabled = true,              .created_by = null,       .tz_abbrev = "UTC",
        .tz_offset_secs = 0,          .tz_source = .controller_local,
    };
    const b: Event = .{
        .epoch = 100,                 .target_label = "host-b", .id = "a",
        .schedule = "",               .command = "",            .foreign = false,
        .enabled = true,              .created_by = null,       .tz_abbrev = "UTC",
        .tz_offset_secs = 0,          .tz_source = .controller_local,
    };
    // host-a < host-b regardless of id
    try testing.expect(lessThan({}, a, b));
    const c: Event = .{
        .epoch = 100,                 .target_label = "host-a", .id = "y",
        .schedule = "",               .command = "",            .foreign = false,
        .enabled = true,              .created_by = null,       .tz_abbrev = "UTC",
        .tz_offset_secs = 0,          .tz_source = .controller_local,
    };
    // same epoch + target → id breaks the tie
    try testing.expect(lessThan({}, c, a));
}
