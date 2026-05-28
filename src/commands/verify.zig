//! `verify` — confirm a managed job will actually fire (#7). "The
//! crontab was written" is not "the job will run": the schedule might
//! resolve to no future time, the cron daemon might be down, the
//! wrapper binary might have moved, or the command might not be on the
//! cron-environment PATH. An agent that adds a job and gets exit 0 has
//! no way to know any of this short of waiting for the fire time — which
//! is unacceptable for loops that close in seconds.
//!
//! verify runs a set of independent, structured checks outside-in and
//! reports each as pass / fail / unknown. Overall `ok` is true iff no
//! check definitively FAILED — an "unknown" (we couldn't probe, e.g.
//! lack the privilege to see the daemon) is surfaced but never counted
//! as a failure, so a green verify never gives false confidence and a
//! restricted environment never produces a false alarm.
//!
//! Scope (v0.3 #7): schedule / command / daemon, plus a wrapper check
//! for wrapped jobs. Deferred: SELinux/AppArmor denials, remote-host
//! probing over ssh, `--skip`, `--explain`, and `doctor` integration.
//! Remediation is out of scope by design — verify reports, it does not fix.

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
const preflight = @import("preflight.zig");
const core = @import("core.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;
const TzInfo = tz_mod.TzInfo;

pub const SCHEMA_VERSION: u32 = 1;

const Status = enum {
    pass,
    fail,
    /// Couldn't determine — a privilege boundary, an unparseable command,
    /// or a target we can't probe. Never a failure (see file header).
    unknown,
    fn str(self: Status) []const u8 {
        return switch (self) {
            .pass => "pass",
            .fail => "fail",
            .unknown => "unknown",
        };
    }
};

const Check = struct {
    name: []const u8,
    status: Status,
    /// Human-readable extra context (the binary found, the failure
    /// reason). Optional; emitted as `detail` in JSON when present.
    detail: ?[]const u8 = null,
    /// Set only by `schedule_resolves` when a concrete next fire exists.
    next_run: ?i64 = null,

    /// "ok" means "did not detect a problem": pass and unknown both
    /// qualify; only an outright fail is not-ok.
    fn ok(self: Check) bool {
        return self.status != .fail;
    }
};

fn allOk(checks: []const Check) bool {
    for (checks) |c| if (!c.ok()) return false;
    return true;
}

fn checkSchedule(j: model.Job, now: i64, tz: TzInfo) Check {
    const sched = sched_mod.parseSchedule(j.schedule) catch
        return .{ .name = "schedule_resolves", .status = .fail, .detail = "schedule does not parse" };
    if (core.nextFor(sched, now, tz)) |nr| {
        return .{ .name = "schedule_resolves", .status = .pass, .next_run = nr };
    }
    if (sched.reboot) {
        return .{ .name = "schedule_resolves", .status = .pass, .detail = "fires at boot (@reboot)" };
    }
    return .{ .name = "schedule_resolves", .status = .fail, .detail = "resolves to no future fire time" };
}

fn checkCommand(a: std.mem.Allocator, t: Target, j: model.Job) Check {
    const bin = preflight.extractBinary(j.command) orelse
        return .{ .name = "command_resolvable", .status = .unknown, .detail = "command is a shell construct; not statically checkable" };
    return switch (preflight.commandReachable(a, t, bin)) {
        .found => .{ .name = "command_resolvable", .status = .pass, .detail = bin },
        .missing => .{ .name = "command_resolvable", .status = .fail, .detail = std.fmt.allocPrint(a, "not found on PATH: {s}", .{bin}) catch "binary not found" },
        // file targets, `-u` remote, or shell-meta names: can't probe.
        .skipped => .{ .name = "command_resolvable", .status = .unknown, .detail = "no execution context to probe this target" },
    };
}

/// Only wrapped jobs (one-shot / capture) carry a `wrapper_bin` — the
/// looper path baked into the cron payload. If it has moved, the job
/// fires but `_exec` can't launch. Non-wrapped jobs return null (no
/// check added).
fn checkWrapper(a: std.mem.Allocator, t: Target, j: model.Job) ?Check {
    const wb = j.wrapper_bin orelse return null;
    if (t.kind == .remote)
        return .{ .name = "wrapper_resolvable", .status = .unknown, .detail = "remote wrapper probe not supported in v0.3" };
    const z = a.dupeZ(u8, wb) catch
        return .{ .name = "wrapper_resolvable", .status = .unknown, .detail = wb };
    if (posix.c.access(z.ptr, posix.c.X_OK) == 0)
        return .{ .name = "wrapper_resolvable", .status = .pass, .detail = wb };
    return .{ .name = "wrapper_resolvable", .status = .fail, .detail = std.fmt.allocPrint(a, "wrapper binary not executable: {s}", .{wb}) catch "wrapper binary missing" };
}

/// Best-effort liveness probe for the cron daemon. systemd first (the
/// definitive answer on modern Linux), then `pgrep` (covers macOS and
/// sysvinit). A negative result is `unknown`, not `fail`: without root
/// we can't reliably distinguish "cron is down" from "cron is running
/// but I can't see it." Computed once per target and shared across jobs.
fn checkDaemon(a: std.mem.Allocator, t: Target) Check {
    if (t.kind == .remote)
        return .{ .name = "daemon_active", .status = .unknown, .detail = "remote daemon probe not supported in v0.3" };
    const probe =
        "systemctl is-active --quiet cron 2>/dev/null || " ++
        "systemctl is-active --quiet crond 2>/dev/null || " ++
        "systemctl is-active --quiet cronie 2>/dev/null || " ++
        "pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x cronie >/dev/null 2>&1";
    const r = posix.runCapture(a, &[_][]const u8{ "/bin/sh", "-c", probe }, null) catch
        return .{ .name = "daemon_active", .status = .unknown, .detail = "could not run daemon probe" };
    if (r.code == 0)
        return .{ .name = "daemon_active", .status = .pass, .detail = "cron daemon active" };
    return .{ .name = "daemon_active", .status = .unknown, .detail = "no running cron daemon detected (may be inactive or not visible to this user)" };
}

fn checksFor(a: std.mem.Allocator, t: Target, j: model.Job, now: i64, tz: TzInfo, daemon: Check) ![]const Check {
    var list: std.ArrayList(Check) = .empty;
    try list.append(a, checkSchedule(j, now, tz));
    try list.append(a, daemon);
    try list.append(a, checkCommand(a, t, j));
    if (checkWrapper(a, t, j)) |w| try list.append(a, w);
    return list.items;
}

fn emitChecksJson(ctx: *Ctx, checks: []const Check) void {
    ctx.emit("[", .{});
    for (checks, 0..) |c, i| {
        if (i > 0) ctx.emit(",", .{});
        ctx.emit("{{\"name\":\"{s}\",\"ok\":{s},\"status\":\"{s}\"", .{
            c.name, if (c.ok()) "true" else "false", c.status.str(),
        });
        if (c.detail) |d| ctx.emit(",\"detail\":\"{s}\"", .{display.jsonEsc(ctx.a, d)});
        if (c.next_run) |nr| ctx.emit(",\"next_run\":{d}", .{nr});
        ctx.emit("}}", .{});
    }
    ctx.emit("]", .{});
}

fn emitJobHuman(ctx: *Ctx, label: []const u8, checks: []const Check, tz: TzInfo) void {
    var passed: usize = 0;
    for (checks) |c| {
        const mark: []const u8 = switch (c.status) {
            .pass => "ok",
            .fail => "XX",
            .unknown => "??",
        };
        const col: []const u8 = switch (c.status) {
            .pass => colors.GREEN,
            .fail => colors.RED,
            .unknown => colors.YELLOW,
        };
        if (c.status == .pass) passed += 1;
        ctx.emit("  {s}{s}{s}  {s}", .{ ctx.k(col), mark, ctx.k(colors.RESET), display.padTo(ctx.a, c.name, 20) });
        if (c.next_run) |nr| {
            ctx.emit("next run {s}", .{humanize.fmtWhenIn(ctx.a, nr, tz)});
        } else if (c.detail) |d| {
            ctx.emit("{s}", .{d});
        }
        ctx.emit("\n", .{});
    }
    const job_ok = allOk(checks);
    const verdict_col = if (job_ok) colors.GREEN else colors.RED;
    ctx.emit("{s}verify {s}{s} {s}— {d}/{d} checks passed\n", .{
        ctx.k(verdict_col), if (job_ok) "ok" else "FAILED", ctx.k(colors.RESET),
        label, passed, checks.len,
    });
}

pub fn cmdVerify(ctx: *Ctx, t: Target, content: []const u8, tz: TzInfo, id: ?[]const u8) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const now = posix.nowEpoch();
    const target_label = t.label(ctx.a);
    // One daemon probe per target; every job on this target shares it.
    const daemon = checkDaemon(ctx.a, t);

    // Single-job mode: `verify <id>`.
    if (id) |want| {
        const idx = ct.findIndex(want) orelse {
            posix.eprint("looper: no managed job '{s}' on {s}\n", .{ want, target_label });
            posix.eprint("  (try: looper -f ... ls)\n", .{});
            ctx.fail(2);
            return;
        };
        const j = ct.items.items[idx].job;
        const checks = try checksFor(ctx.a, t, j, now, tz, daemon);
        const job_ok = allOk(checks);
        if (ctx.json) {
            ctx.emit("{{\"schema_version\":{d},\"target\":\"{s}\",\"id\":\"{s}\",\"ok\":{s},\"checks\":", .{
                SCHEMA_VERSION, display.jsonEsc(ctx.a, target_label), display.jsonEsc(ctx.a, want), if (job_ok) "true" else "false",
            });
            emitChecksJson(ctx, checks);
            ctx.emit("}}\n", .{});
        } else {
            ctx.emit("{s}verify {s}{s} on {s}\n", .{ ctx.k(colors.BOLD), want, ctx.k(colors.RESET), target_label });
            emitJobHuman(ctx, want, checks, tz);
        }
        if (!job_ok) ctx.fail(1);
        return;
    }

    // All-jobs mode: `verify` with no id checks every managed job.
    if (ctx.json) {
        ctx.emit("{{\"schema_version\":{d},\"target\":\"{s}\",\"jobs\":[", .{ SCHEMA_VERSION, display.jsonEsc(ctx.a, target_label) });
        var first = true;
        var any_failed = false;
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                if (j.foreign) continue;
                const checks = try checksFor(ctx.a, t, j, now, tz, daemon);
                const job_ok = allOk(checks);
                if (!job_ok) any_failed = true;
                if (!first) ctx.emit(",", .{});
                first = false;
                ctx.emit("{{\"id\":\"{s}\",\"ok\":{s},\"checks\":", .{ display.jsonEsc(ctx.a, j.id), if (job_ok) "true" else "false" });
                emitChecksJson(ctx, checks);
                ctx.emit("}}", .{});
            },
            else => {},
        };
        ctx.emit("]}}\n", .{});
        if (any_failed) ctx.fail(1);
        return;
    }

    var any_failed = false;
    var any_job = false;
    for (ct.items.items) |it| switch (it) {
        .job => |j| {
            if (j.foreign) continue;
            any_job = true;
            const checks = try checksFor(ctx.a, t, j, now, tz, daemon);
            if (!allOk(checks)) any_failed = true;
            ctx.emit("{s}{s}{s} on {s}\n", .{ ctx.k(colors.BOLD), j.id, ctx.k(colors.RESET), target_label });
            emitJobHuman(ctx, j.id, checks, tz);
            ctx.emit("\n", .{});
        },
        else => {},
    };
    if (!any_job) ctx.emit("{s}no managed jobs to verify on {s}{s}\n", .{ ctx.k(colors.DIM), target_label, ctx.k(colors.RESET) });
    if (any_failed) ctx.fail(1);
}

const testing = std.testing;

test "checkSchedule: valid schedule resolves to a future fire" {
    const tz: TzInfo = .{ .abbrev = "UTC", .offset_secs = 0, .source = .controller_local };
    const j: model.Job = .{ .id = "x", .enabled = true, .schedule = "@daily", .command = "/bin/true" };
    const c = checkSchedule(j, 1_700_000_000, tz);
    try testing.expectEqualStrings("schedule_resolves", c.name);
    try testing.expectEqual(Status.pass, c.status);
    try testing.expect(c.next_run != null);
}

test "checkSchedule: unparseable schedule fails" {
    const tz: TzInfo = .{ .abbrev = "UTC", .offset_secs = 0, .source = .controller_local };
    const j: model.Job = .{ .id = "x", .enabled = true, .schedule = "not a schedule", .command = "/bin/true" };
    const c = checkSchedule(j, 1_700_000_000, tz);
    try testing.expectEqual(Status.fail, c.status);
    try testing.expect(!c.ok());
}

test "checkCommand: existing binary passes, shell construct is unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    const ok_job: model.Job = .{ .id = "x", .enabled = true, .schedule = "@daily", .command = "/bin/sh -c work" };
    const okc = checkCommand(a, t, ok_job);
    try testing.expectEqual(Status.pass, okc.status);

    const sh_job: model.Job = .{ .id = "y", .enabled = true, .schedule = "@daily", .command = "$VAR_NOT_A_BINARY" };
    const unk = checkCommand(a, t, sh_job);
    try testing.expectEqual(Status.unknown, unk.status);
    try testing.expect(unk.ok()); // unknown is not a failure
}

test "checkCommand: missing binary fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    const j: model.Job = .{ .id = "x", .enabled = true, .schedule = "@daily", .command = "/zzz/definitely/not/here arg" };
    const c = checkCommand(a, t, j);
    try testing.expectEqual(Status.fail, c.status);
}

test "allOk: unknown does not fail, an explicit fail does" {
    const pass: Check = .{ .name = "a", .status = .pass };
    const unknown: Check = .{ .name = "b", .status = .unknown };
    const fail: Check = .{ .name = "c", .status = .fail };
    try testing.expect(allOk(&[_]Check{ pass, unknown }));
    try testing.expect(!allOk(&[_]Check{ pass, unknown, fail }));
}

test "checksFor: produces at least the three base checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tz: TzInfo = .{ .abbrev = "UTC", .offset_secs = 0, .source = .controller_local };
    const t: Target = .{ .kind = .file, .path = "/tmp/x" };
    const j: model.Job = .{ .id = "x", .enabled = true, .schedule = "@daily", .command = "/bin/true" };
    const daemon: Check = .{ .name = "daemon_active", .status = .unknown };
    const checks = try checksFor(a, t, j, 1_700_000_000, tz, daemon);
    try testing.expect(checks.len >= 3);
    try testing.expectEqualStrings("schedule_resolves", checks[0].name);
    try testing.expectEqualStrings("daemon_active", checks[1].name);
    try testing.expectEqualStrings("command_resolvable", checks[2].name);
}
