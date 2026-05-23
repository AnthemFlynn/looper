//! `doctor` preflight: report on everything that could fail
//! one-target-at-a-time mid-command — missing binaries, unwritable
//! backup dir, unreadable hosts file, dead ssh, no-crontab-for-user.
//! Mutates nothing; touches the filesystem only to (re)create the
//! backup dir and drop a probe file inside it.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const backup_mod = @import("../crontab/backup.zig");
const colors = @import("../ui/colors.zig");
const tz_probe = @import("../tz_probe.zig");
const preflight = @import("preflight.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

const CheckStatus = enum { ok, warn, fail };

fn printCheck(ctx: *Ctx, st: CheckStatus, name: []const u8, detail: []const u8) void {
    const sym: []const u8 = switch (st) {
        .ok => "\xe2\x9c\x93", // ✓
        .warn => "!",
        .fail => "\xe2\x9c\x97", // ✗
    };
    const color: []const u8 = switch (st) {
        .ok => ctx.k(colors.GREEN),
        .warn => ctx.k(colors.YELLOW),
        .fail => ctx.k(colors.RED),
    };
    ctx.emit("  {s}{s}{s} {s}  {s}{s}{s}\n", .{
        color,             sym,    ctx.k(colors.RESET),
        name,
        ctx.k(colors.DIM), detail, ctx.k(colors.RESET),
    });
}

/// True iff we can create and remove a probe file inside `dir`. Creates
/// the directory tree first — matches the lazy mkdir doBackup does on
/// first mutation, so the doctor check tells you the same thing the real
/// write would tell you.
pub fn dirWritable(a: std.mem.Allocator, dir: []const u8) bool {
    backup_mod.mkdirP(a, dir);
    const probe = std.fmt.allocPrint(a, "{s}/.looper-probe-{x}", .{ dir, posix.nowEpoch() }) catch return false;
    const pz = a.dupeZ(u8, probe) catch return false;
    const fd = posix.c.open(pz.ptr, posix.c.O_WRONLY | posix.c.O_CREAT | posix.c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    _ = posix.c.close(fd);
    _ = posix.c.unlink(pz.ptr);
    return true;
}

pub fn fileReadable(a: std.mem.Allocator, path: []const u8) bool {
    const pz = a.dupeZ(u8, path) catch return false;
    const fd = posix.c.open(pz.ptr, posix.c.O_RDONLY);
    if (fd < 0) return false;
    _ = posix.c.close(fd);
    return true;
}

/// `ssh -o BatchMode=yes -o ConnectTimeout=10 host true` — the cheapest
/// thing that proves the connection works under the same constraints the
/// real backend uses. BatchMode + key-only auth means a missing key fails
/// here rather than hanging on a password prompt the way `crontab -l`
/// would on first use.
fn sshReachable(a: std.mem.Allocator, host: []const u8) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    const prefix = target_mod.sshArgvPrefix(a, host) catch return false;
    argv.appendSlice(a, prefix) catch return false;
    argv.append(a, "true") catch return false;
    const r = posix.runCapture(a, argv.items, null) catch return false;
    return r.code == 0;
}

pub fn cmdDoctor(ctx: *Ctx, targets: []const Target, hosts_path: []const u8, use_all: bool) !void {
    var fails: usize = 0;
    var warns: usize = 0;

    var has_local = false;
    var has_remote = false;
    for (targets) |t| switch (t.kind) {
        .local => has_local = true,
        .remote => has_remote = true,
        .file => {},
    };

    ctx.emit("{s}environment{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.RESET) });
    if (has_local) {
        if (preflight.hasInPath(ctx.a, "crontab")) {
            printCheck(ctx, .ok, "crontab", "found in PATH");
        } else {
            printCheck(ctx, .fail, "crontab", "missing — required for local targets");
            fails += 1;
        }
    }
    if (has_remote) {
        if (preflight.hasInPath(ctx.a, "ssh")) {
            printCheck(ctx, .ok, "ssh", "found in PATH");
        } else {
            printCheck(ctx, .fail, "ssh", "missing — required for -H/--all");
            fails += 1;
        }
    }
    const sdir = backup_mod.stateDir(ctx.a);
    const bdir = std.fmt.allocPrint(ctx.a, "{s}/backups", .{sdir}) catch sdir;
    if (dirWritable(ctx.a, bdir)) {
        printCheck(ctx, .ok, "backup dir", bdir);
    } else {
        printCheck(ctx, .fail, "backup dir", bdir);
        fails += 1;
    }
    if (use_all) {
        const have_file = hosts_path.len > 0 and fileReadable(ctx.a, hosts_path);
        if (have_file) {
            printCheck(ctx, .ok, "hosts file", hosts_path);
            if (targets.len == 0) {
                printCheck(ctx, .fail, "hosts entries", "no usable hosts (every line blank or a comment)");
                fails += 1;
            }
        } else {
            const detail = if (hosts_path.len > 0) hosts_path else "(no path resolved)";
            printCheck(ctx, .fail, "hosts file", detail);
            fails += 1;
        }
    } else if (hosts_path.len > 0) {
        ctx.emit("  {s}-  hosts file (unused)  {s}{s}\n", .{ ctx.k(colors.DIM), hosts_path, ctx.k(colors.RESET) });
    }

    ctx.emit("\n{s}targets{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.RESET) });
    if (targets.len == 0) {
        ctx.emit("  {s}(no targets){s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET) });
    }
    for (targets) |t| {
        ctx.emit("  {s}{s}{s}{s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.CYAN), t.label(ctx.a), ctx.k(colors.RESET) });
        if (t.kind == .remote) {
            if (sshReachable(ctx.a, t.host)) {
                printCheck(ctx, .ok, "ssh reachable", t.host);
            } else {
                printCheck(ctx, .fail, "ssh reachable", "no connection (BatchMode, ConnectTimeout=10)");
                fails += 1;
                continue; // skip read attempt — it would just block or hang
            }
        }
        if (target_mod.readCrontab(ctx.a, t)) |content| {
            const line_count = std.mem.count(u8, content, "\n");
            const detail = std.fmt.allocPrint(ctx.a, "{d} line(s)", .{line_count}) catch "ok";
            printCheck(ctx, .ok, "crontab readable", detail);
        } else |e| {
            printCheck(ctx, .fail, "crontab readable", @errorName(e));
            fails += 1;
        }
        // Per-remote-target TZ probe — degraded path (probe fails) is a
        // warning, not a fail: looper still works, just labels remote
        // times as `(controller-local)` rather than rendering in target
        // wall clock.
        if (t.kind == .remote) {
            if (ctx.no_target_tz) {
                printCheck(ctx, .ok, "target tz", "skipped (--no-target-tz)");
            } else if (tz_probe.probeRemote(ctx.a, t.host)) |tz| {
                const detail = std.fmt.allocPrint(ctx.a, "{s} (UTC{c}{d:0>2}:{d:0>2})", .{
                    tz.abbrev,
                    @as(u8, if (tz.offset_secs < 0) '-' else '+'),
                    @as(u32, @intCast(@divTrunc(if (tz.offset_secs < 0) -tz.offset_secs else tz.offset_secs, 3600))),
                    @as(u32, @intCast(@divTrunc(@mod(if (tz.offset_secs < 0) -tz.offset_secs else tz.offset_secs, 3600), 60))),
                }) catch tz.abbrev;
                printCheck(ctx, .ok, "target tz", detail);
            } else {
                printCheck(ctx, .warn, "target tz", "probe failed — will fall back to (controller-local) labeling");
                warns += 1;
            }
        }
    }

    ctx.emit("\n", .{});
    if (fails > 0) {
        ctx.emit("{s}{d} check(s) failed — fix before relying on looper{s}\n", .{
            ctx.k(colors.RED), fails, ctx.k(colors.RESET),
        });
        if (warns > 0) ctx.emit("{s}{d} warning(s) — looper still works, see notes above{s}\n", .{
            ctx.k(colors.YELLOW), warns, ctx.k(colors.RESET),
        });
        ctx.fail(1);
    } else if (warns > 0) {
        ctx.emit("{s}{d} warning(s) — looper still works, see notes above{s}\n", .{
            ctx.k(colors.YELLOW), warns, ctx.k(colors.RESET),
        });
    } else {
        ctx.emit("{s}\xe2\x9c\x93 all checks passed{s}\n", .{ ctx.k(colors.GREEN), ctx.k(colors.RESET) });
    }
}

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

test "dirWritable succeeds on /tmp and fails on a non-creatable path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(dirWritable(a, "/tmp"));
    // `/proc/looper-doctor-test` — root-owned read-only synthetic fs on
    // Linux, ENOENT on macOS; both yield a failing mkdir/open, which is
    // the case we want to exercise.
    try testing.expect(!dirWritable(a, "/proc/looper-doctor-test-xyz"));
}

test "fileReadable detects present and missing files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "/tmp/looper-readable-test-{x}", .{posix.nowEpoch()});
    defer _ = posix.c.unlink((a.dupeZ(u8, path) catch unreachable).ptr);
    try target_mod.writeFileAll(a, path, "hi\n");
    try testing.expect(fileReadable(a, path));
    try testing.expect(!fileReadable(a, "/tmp/looper-definitely-not-here-zzz-xyz"));
}

test "cmdDoctor against a file target passes and writes a structured report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    // File target = no `crontab`/`ssh` env checks, just backup-dir +
    // per-target read of the file. Empty path returns empty content,
    // which still counts as a successful read (0 lines).
    const path = try std.fmt.allocPrint(a, "/tmp/looper-doctor-it-{x}.crontab", .{posix.nowEpoch()});
    defer _ = posix.c.unlink((a.dupeZ(u8, path) catch unreachable).ptr);
    try target_mod.writeFileAll(a, path, "# nothing here\n");
    var targets = [_]Target{.{ .kind = .file, .path = path }};
    try cmdDoctor(&ctx, targets[0..], "/nonexistent/hosts", false);
    try testing.expectEqual(@as(u8, 0), ctx.exit_code);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "environment") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "backup dir") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "crontab readable") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "all checks passed") != null);
    // No env checks for crontab/ssh when only a file target is in play.
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "ssh  found") == null);
}

test "cmdDoctor --all with missing hosts file fails the run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    var targets = [_]Target{};
    try cmdDoctor(&ctx, targets[0..], "/tmp/looper-missing-hosts-zzz", true);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "hosts file") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "check(s) failed") != null);
}
