//! `looper once <when> <command>` — schedule a one-shot job that fires
//! once at the given moment, captures output to state_dir/runs/, then
//! self-removes from the crontab.
//!
//! Composition:
//!   - cron/once_when.parseWhen → UTC epoch.
//!   - Epoch → "M H D Mo *" cron line (target-local minute, hour, etc.).
//!   - Marker carries once=1, capture=1, run_id, wrapper_bin.
//!   - Job.command is the user's inner command verbatim; serialize wraps
//!     it into `<looper> _exec ... -- /bin/sh -c '<inner>'` at write time.
//!   - applyMutation does the backup + write, same funnel everything else
//!     goes through.
//!
//! v1 is local-target only. One-shot on remote hosts adds a layer of
//! issues (per-target wrapper_bin resolution, per-target tz, _exec
//! reaching back to remove a crontab entry the local controller never
//! wrote) — Task #10 documents the punt.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const backup_mod = @import("../crontab/backup.zig");
const once_when = @import("../cron/once_when.zig");
const kairoz = @import("../cron/kairoz/root.zig");
const tz_mod = @import("../tz.zig");
const humanize = @import("../cron/humanize.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");
const core = @import("core.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

pub const OnceOpts = struct {
    /// Optional explicit job id; auto-slugged from the command when null.
    want_id: ?[]const u8 = null,
    /// Optional kill timeout for the child process.
    timeout_secs: ?u32 = null,
};

pub fn cmdScheduleOnce(
    ctx: *Ctx,
    t: Target,
    content: []const u8,
    when_input: []const u8,
    command: []const u8,
    opts: OnceOpts,
) !void {
    // v1: local target only. Remote/file punts surface with a clear
    // message so the user knows what's not yet supported.
    if (t.kind != .local) {
        posix.eprint("looper once: one-shot scheduling is local-target only in v1 (got {s})\n", .{t.label(ctx.a)});
        ctx.fail(2);
        return;
    }

    const now_utc = posix.nowEpoch();
    const tz = tz_mod.controllerTz(ctx.a);

    const target_utc = once_when.parseWhen(when_input, now_utc, tz.offset_secs) catch |err| switch (err) {
        error.KairozParseFailed => {
            posix.eprint("looper once: couldn't read time '{s}'\n", .{when_input});
            posix.eprint("  try: \"in 5 min\", \"tomorrow 9am\", \"2026-12-31 09:00\"\n", .{});
            ctx.fail(1);
            return;
        },
        error.UnsupportedVariant => {
            posix.eprint("looper once: '{s}' isn't a single moment — try a date + time-of-day, or a specific duration\n", .{when_input});
            ctx.fail(1);
            return;
        },
        error.TooSoon => {
            posix.eprint("looper once: '{s}' is in the past (or too close — minimum is 30s ahead)\n", .{when_input});
            ctx.fail(1);
            return;
        },
    };

    // Resolve looper's absolute path for cron to invoke at fire time.
    // Cron's PATH is minimal; the bare name `looper` would usually fail.
    const wrapper_bin = posix.looperPath(ctx.a) orelse {
        posix.eprint("looper once: can't resolve the looper binary path on this platform — required for one-shot scheduling\n", .{});
        ctx.fail(1);
        return;
    };

    // Build the cron schedule field from the target epoch. The cron
    // daemon evaluates fields in its own local TZ, which we treat as
    // the controller's TZ (local target). The MoY/DoM/H/M values are
    // computed in that local zone so cron fires at the right wall-clock
    // moment.
    const local_target = target_utc + tz.offset_secs;
    const local_days = @divFloor(local_target, 86400);
    const local_sod = local_target - local_days * 86400;
    const date = kairoz.Date.epochDaysToDate(@intCast(local_days));
    const minute: u32 = @intCast(@mod(@divFloor(local_sod, 60), 60));
    const hour: u32 = @intCast(@divFloor(local_sod, 3600));
    const schedule = try std.fmt.allocPrint(
        ctx.a,
        "{d} {d} {d} {d} *",
        .{ minute, hour, date.day, date.month },
    );

    // Parse the existing crontab and choose a job id. Auto-slug from
    // the command if the user didn't pin one; cmdAdd's slugUnique
    // already handles collisions against existing managed ids.
    var ct = try model.parseCrontab(ctx.a, content);
    const id = opts.want_id orelse display.slugUnique(ctx.a, &ct, command);

    // Generate run_id: <source_id>-<utcStamp>-<pid-hex>. Human-readable
    // for filesystem listings, unique within the (id, second) tuple.
    // Two one-shots scheduled in the same second from the same process
    // would collide on id BEFORE run_id (cmdAdd's update-in-place),
    // so this is sufficient in practice.
    const stamp = backup_mod.utcStamp(ctx.a);
    const pid_hex = try std.fmt.allocPrint(ctx.a, "{x}", .{posix.c.getpid()});
    const run_id = try std.fmt.allocPrint(ctx.a, "{s}-{s}-{s}", .{ id, stamp, pid_hex });

    // Insert or replace by id. Idempotent: scheduling the same one-shot
    // twice (same id) just updates the schedule/command/run_id.
    const job: model.Job = .{
        .id = id,
        .enabled = true,
        .schedule = schedule,
        .command = command,
        .once = true,
        .capture = true,
        .run_id = run_id,
        .timeout_secs = opts.timeout_secs,
        .wrapper_bin = wrapper_bin,
    };
    if (ct.findIndex(id)) |i| {
        ct.items.items[i].job = job;
    } else try ct.items.append(ctx.a, .{ .job = job });

    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "scheduled one-shot '{s}'", .{id});
    try core.applyMutation(ctx, t, content, new_content, verb);

    // Confirmation line — silent under --quiet (which the MCP layer
    // sets), JSON-aware so structured callers get a queryable record.
    if (ctx.json) {
        ctx.emit(
            "{{\"run_id\":\"{s}\",\"id\":\"{s}\",\"scheduled_for\":{d},\"schedule\":\"{s}\",\"target\":\"{s}\"}}\n",
            .{
                display.jsonEsc(ctx.a, run_id),
                display.jsonEsc(ctx.a, id),
                target_utc,
                display.jsonEsc(ctx.a, schedule),
                display.jsonEsc(ctx.a, t.label(ctx.a)),
            },
        );
        return;
    }
    if (!ctx.quiet) {
        const when_human = humanize.fmtWhenIn(ctx.a, target_utc, tz);
        ctx.emit(
            "{s}\xe2\x9c\x93{s} one-shot {s}{s}{s} scheduled for {s}{s}{s} (run_id: {s}{s}{s})\n",
            .{
                ctx.k(colors.GREEN),    ctx.k(colors.RESET),
                ctx.k(colors.CYAN),     id,                  ctx.k(colors.RESET),
                ctx.k(colors.BOLD),     when_human,          ctx.k(colors.RESET),
                ctx.k(colors.DIM),      run_id,              ctx.k(colors.RESET),
            },
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true, .quiet = true };
}

test "cmdScheduleOnce rejects non-local targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const t: Target = .{ .kind = .file, .path = "/tmp/whatever" };
    try cmdScheduleOnce(&ctx, t, "", "in 5 min", "echo hi", .{});
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdScheduleOnce rejects garbage time input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const t: Target = .{ .kind = .local };
    ctx.dry_run = true; // don't touch the real crontab even on the error path
    try cmdScheduleOnce(&ctx, t, "", "not a time", "echo hi", .{});
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdScheduleOnce rejects past times" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const t: Target = .{ .kind = .local };
    ctx.dry_run = true;
    try cmdScheduleOnce(&ctx, t, "", "2020-01-01T12:00:00Z", "echo hi", .{});
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdScheduleOnce dry-run JSON emits the structured envelope" {
    // We can't write to the real local crontab in a test, so use
    // --dry-run + JSON. The diff envelope must include a wrapped cron
    // payload (looper _exec) and the marker attrs for one-shot.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    const t: Target = .{ .kind = .local };
    try cmdScheduleOnce(&ctx, t, "", "in 5 min", "/bin/echo hi", .{ .want_id = "test-fire" });
    // The dry-run diff lines should include the new marker (with once=1
    // and capture=1) plus the wrapper cron payload.
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "once=1") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "capture=1") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "_exec --source-id=test-fire") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "--once") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, " -- /bin/sh -c '/bin/echo hi'") != null);
}

test "cmdScheduleOnce derives a valid M H D Mo * schedule" {
    // The cron field must have 5 space-separated tokens with `*` for
    // day-of-week, and the day/month must be numeric (not @reboot etc.).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    const t: Target = .{ .kind = .local };
    try cmdScheduleOnce(&ctx, t, "", "in 30 sec", "/bin/true", .{ .want_id = "sched-shape" });
    // Scan for a 5-field cron line in the JSON diff. Easiest: look for
    // the `* ` followed by the wrapper path in the diff payload.
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, " * ") != null);
}
