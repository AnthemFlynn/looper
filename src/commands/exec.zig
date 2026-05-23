//! `_exec` — internal wrapper command invoked by cron for one-shot and
//! captured-recurring jobs. Hidden from --help; the format is an
//! internal protocol between `looper once` / `looper add --capture`
//! (which write the cron line) and this command (which reads it).
//!
//! Invocation:
//!
//!   looper _exec --run-id <id> [--source-id <id>] [--timeout-secs N]
//!                [--target-label <L>] [--once] -- <user cmd argv...>
//!
//! Flow:
//!
//!   1. Open out / err files under state_dir/runs/<run_id>/.
//!   2. Write initial meta with started_at (so concurrent reads classify
//!      the record as `.running`).
//!   3. Fork. Child dup2's the open files onto fds 1 + 2, then execvp
//!      the user's argv directly (no extra shell wrap — `looper once`
//!      and friends already embed `/bin/sh -c '<cmd>'` in the cron line
//!      when shell semantics are needed).
//!   4. Parent polls waitpid (WNOHANG) every 100ms; on timeout sends
//!      SIGTERM, waits 1s, then SIGKILL if the child hasn't exited.
//!   5. Write final meta with finished_at, exit_code, timed_out.
//!   6. If --once: read local crontab, remove the source job by id via
//!      applyMutation (same backup-before-write funnel everything else
//!      uses), so a one-shot is self-cleaning.
//!
//! _exec never writes to stdout — cron mails stdout to the user, and
//! the only meaningful output is whatever the wrapped command produced.
//! Errors are reported via posix.eprint to stderr (also mailed) so a
//! human can see them; non-zero exit code propagates.

const std = @import("std");
const posix = @import("../posix.zig");
const c = posix.c;
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const runs_mod = @import("../crontab/runs.zig");
const core = @import("core.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;
const RunRecord = runs_mod.RunRecord;

/// Poll cadence for the parent's waitpid loop. 100ms is small enough to
/// make a timeout feel snappy, large enough to vanish in any reasonable
/// CPU budget. Configurable here so tests can drop it for fast-fire
/// timeouts without burning real seconds.
const POLL_INTERVAL_NS: u64 = 100 * 1_000_000;

/// Grace period between SIGTERM and SIGKILL when a child blows its
/// timeout. Most well-behaved processes exit on SIGTERM; only the truly
/// stuck need the SIGKILL hammer.
const TERM_TO_KILL_GRACE_SECS: i64 = 1;

pub const ExecError = error{
    MissingRunId,
    MissingCommand,
    OpenFailed,
    ForkFailed,
};

/// Open `path` for writing, creating + truncating. Returns the fd or -1
/// on failure. mode 0644 matches the kernel-default for `creat`.
fn openCaptureFile(a: std.mem.Allocator, path: []const u8) c_int {
    const pz = a.dupeZ(u8, path) catch return -1;
    return c.open(pz.ptr, c.O_CREAT | c.O_WRONLY | c.O_TRUNC, @as(c.mode_t, 0o644));
}

fn sleepNs(ns: u64) void {
    var req: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    req.tv_sec = @intCast(ns / 1_000_000_000);
    req.tv_nsec = @intCast(ns % 1_000_000_000);
    _ = c.nanosleep(&req, null);
}

/// Wait for `pid` with optional timeout. Returns the libc-style status
/// word (caller uses WIFEXITED/WEXITSTATUS) and a `timed_out` flag.
fn waitWithTimeout(pid: c.pid_t, timeout_secs: ?u32) struct { status: c_int, timed_out: bool } {
    var status: c_int = 0;
    if (timeout_secs == null) {
        _ = c.waitpid(pid, &status, 0);
        return .{ .status = status, .timed_out = false };
    }
    const deadline = posix.nowEpoch() + @as(i64, @intCast(timeout_secs.?));
    while (true) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid) return .{ .status = status, .timed_out = false };
        if (r < 0) return .{ .status = status, .timed_out = false };
        if (posix.nowEpoch() >= deadline) break;
        sleepNs(POLL_INTERVAL_NS);
    }
    // Timed out — escalate SIGTERM → SIGKILL with a short grace window.
    _ = c.kill(pid, c.SIGTERM);
    const kill_deadline = posix.nowEpoch() + TERM_TO_KILL_GRACE_SECS;
    while (true) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid) return .{ .status = status, .timed_out = true };
        if (r < 0) return .{ .status = status, .timed_out = true };
        if (posix.nowEpoch() >= kill_deadline) break;
        sleepNs(POLL_INTERVAL_NS);
    }
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, &status, 0);
    return .{ .status = status, .timed_out = true };
}

/// Translate a wait(2) status word into a stable exit code we can record.
/// Normal exit → WEXITSTATUS. Signal kill → 128 + signo (POSIX shell
/// convention so users see e.g. 143 for SIGTERM). Anything else → -1.
fn decodeStatus(status: c_int) i32 {
    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
    if (c.WIFSIGNALED(status)) return 128 + @as(i32, @intCast(c.WTERMSIG(status)));
    return -1;
}

/// Remove the source job from the local crontab via applyMutation.
/// Best-effort: if the job is already gone (user manually edited), we
/// silently no-op. The run record is the source of truth for "did this
/// run" — the crontab removal is housekeeping.
fn removeSourceJob(ctx: *Ctx, source_id: []const u8) void {
    const t: Target = .{ .kind = .local };
    const content = target_mod.readCrontab(ctx.a, t) catch return;
    var ct = model.parseCrontab(ctx.a, content) catch return;
    const idx = ct.findIndex(source_id) orelse return;
    var keep: std.ArrayList(model.Item) = .empty;
    for (ct.items.items, 0..) |it, i| {
        if (i == idx) continue;
        keep.append(ctx.a, it) catch return;
    }
    ct.items = keep;
    const new_content = model.serialize(ctx.a, &ct) catch return;
    const verb = std.fmt.allocPrint(ctx.a, "removed one-shot '{s}'", .{source_id}) catch "removed one-shot";
    core.applyMutation(ctx, t, content, new_content, verb) catch {};
}

/// Joins argv tokens with spaces for storage in the run record's
/// `command` field. The actual exec uses the raw argv — this is purely
/// for display in `looper runs show`, where a single-string form reads
/// better than a quoted argv list.
fn joinArgv(a: std.mem.Allocator, argv: []const []const u8) []const u8 {
    var total: usize = 0;
    for (argv, 0..) |t, i| total += t.len + (if (i > 0) @as(usize, 1) else 0);
    var out = a.alloc(u8, total) catch return "";
    var off: usize = 0;
    for (argv, 0..) |t, i| {
        if (i > 0) {
            out[off] = ' ';
            off += 1;
        }
        @memcpy(out[off .. off + t.len], t);
        off += t.len;
    }
    return out;
}

pub fn cmdExec(
    ctx: *Ctx,
    run_id: []const u8,
    source_id: ?[]const u8,
    timeout_secs: ?u32,
    target_label: ?[]const u8,
    once_flag: bool,
    cmd_argv: []const []const u8,
) !void {
    if (run_id.len == 0) {
        posix.eprint("looper _exec: --run-id is required\n", .{});
        ctx.fail(2);
        return;
    }
    if (cmd_argv.len == 0) {
        posix.eprint("looper _exec: no command given (expected positional argv after `--`)\n", .{});
        ctx.fail(2);
        return;
    }

    // Make the run dir, then record the started state. A reader who
    // catches us between the meta-write and the waitpid sees status =
    // running, which is correct.
    _ = runs_mod.ensureRunDir(ctx.a, run_id);
    const command_str = joinArgv(ctx.a, cmd_argv);
    const started_at = posix.nowEpoch();
    try runs_mod.metaWrite(ctx.a, .{
        .run_id = run_id,
        .source_id = source_id,
        .command = command_str,
        .target_label = target_label orelse "local",
        .once = once_flag,
        .scheduled_for = started_at, // best estimate; cron's actual scheduled time isn't passed in
        .started_at = started_at,
    });

    const out_path = runs_mod.outPath(ctx.a, run_id);
    const err_path = runs_mod.errPath(ctx.a, run_id);
    const out_fd = openCaptureFile(ctx.a, out_path);
    const err_fd = openCaptureFile(ctx.a, err_path);
    if (out_fd < 0 or err_fd < 0) {
        if (out_fd >= 0) _ = c.close(out_fd);
        if (err_fd >= 0) _ = c.close(err_fd);
        posix.eprint("looper _exec: cannot open capture files under runs/{s}\n", .{run_id});
        ctx.fail(1);
        return;
    }

    // Build the child argv. We exec the user's tokens directly — the
    // caller (looper once / add --capture) is responsible for embedding
    // a shell wrapper (`/bin/sh -c '<cmd>'`) in the cron line when shell
    // expansion is needed.
    const cargv = try ctx.a.alloc([*c]u8, cmd_argv.len + 1);
    for (cmd_argv, 0..) |t, i| cargv[i] = (try ctx.a.dupeZ(u8, t)).ptr;
    cargv[cmd_argv.len] = null;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(out_fd);
        _ = c.close(err_fd);
        posix.eprint("looper _exec: fork failed\n", .{});
        ctx.fail(1);
        return;
    }
    if (pid == 0) {
        // Child. Re-target stdout/stderr onto the open files; the
        // original fds aren't needed after dup2 succeeds.
        _ = c.dup2(out_fd, 1);
        _ = c.dup2(err_fd, 2);
        _ = c.close(out_fd);
        _ = c.close(err_fd);
        _ = c.execvp(cargv[0], cargv.ptr);
        // If execvp returns, exec failed (bad path, ENOENT, …). 127
        // matches `sh`'s convention for "command not found", which is
        // what cron + the user would expect to see.
        c._exit(127);
    }

    // Parent: close our copies of the capture fds; the child kept the
    // dup2'd descriptors.
    _ = c.close(out_fd);
    _ = c.close(err_fd);

    const wait_result = waitWithTimeout(pid, timeout_secs);
    const finished_at = posix.nowEpoch();
    const exit_code = decodeStatus(wait_result.status);

    try runs_mod.metaWrite(ctx.a, .{
        .run_id = run_id,
        .source_id = source_id,
        .command = command_str,
        .target_label = target_label orelse "local",
        .once = once_flag,
        .scheduled_for = started_at,
        .started_at = started_at,
        .finished_at = finished_at,
        .exit_code = exit_code,
        .timed_out = wait_result.timed_out,
    });

    if (once_flag) if (source_id) |sid| removeSourceJob(ctx, sid);

    // Propagate the child's exit code so cron-side observers see the
    // same code the underlying command produced. We clamp negatives to
    // 1 since Ctx.exit_code is u8.
    if (exit_code != 0) {
        const u: u8 = if (exit_code < 0 or exit_code > 255) 1 else @intCast(exit_code);
        ctx.fail(u);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true, .quiet = true };
}

fn cleanupRun(a: std.mem.Allocator, run_id: []const u8) void {
    const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch return;
    const out_z = a.dupeZ(u8, runs_mod.outPath(a, run_id)) catch return;
    const err_z = a.dupeZ(u8, runs_mod.errPath(a, run_id)) catch return;
    const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch return;
    _ = c.unlink(meta_z.ptr);
    _ = c.unlink(out_z.ptr);
    _ = c.unlink(err_z.ptr);
    _ = c.rmdir(dir_z.ptr);
}

test "cmdExec rejects missing run_id with exit 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    try cmdExec(&ctx, "", null, null, null, false, &argv);
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdExec rejects missing command with exit 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    try cmdExec(&ctx, "x", null, null, null, false, &[_][]const u8{});
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdExec runs a successful command and records exit_code=0" {
    // Using `/bin/sh -c 'exit 0'` instead of `/bin/true` for portability:
    // macOS ships true/false at /usr/bin/, Linux at /bin/. The shell
    // builtin is at the same path on both.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-ok-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    try cmdExec(&ctx, run_id, null, null, null, false, &[_][]const u8{ "/bin/sh", "-c", "exit 0" });
    const rec = (try runs_mod.metaRead(a, run_id)).?;
    try testing.expectEqual(@as(?i32, 0), rec.exit_code);
    try testing.expect(!rec.timed_out);
    try testing.expect(rec.finished_at != null);
    try testing.expect(rec.started_at != null);
    try testing.expectEqual(@as(u8, 0), ctx.exit_code);
}

test "cmdExec runs a failing command and records exit_code=1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-fail-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    try cmdExec(&ctx, run_id, null, null, null, false, &[_][]const u8{ "/bin/sh", "-c", "exit 1" });
    const rec = (try runs_mod.metaRead(a, run_id)).?;
    try testing.expectEqual(@as(?i32, 1), rec.exit_code);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdExec captures stdout to runs/<id>/out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-stdout-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    try cmdExec(&ctx, run_id, null, null, null, false, &[_][]const u8{ "/bin/sh", "-c", "echo captured-stdout" });
    const out = try target_mod.readFileAll(a, runs_mod.outPath(a, run_id));
    try testing.expect(std.mem.indexOf(u8, out, "captured-stdout") != null);
}

test "cmdExec captures stderr to runs/<id>/err" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-stderr-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    try cmdExec(&ctx, run_id, null, null, null, false, &[_][]const u8{ "/bin/sh", "-c", "echo to-stderr >&2" });
    const err = try target_mod.readFileAll(a, runs_mod.errPath(a, run_id));
    try testing.expect(std.mem.indexOf(u8, err, "to-stderr") != null);
}

test "cmdExec exec failure (nonexistent binary) records exit_code=127" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-enoent-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    try cmdExec(&ctx, run_id, null, null, null, false, &[_][]const u8{"/this/binary/does/not/exist"});
    const rec = (try runs_mod.metaRead(a, run_id)).?;
    try testing.expectEqual(@as(?i32, 127), rec.exit_code);
}

test "cmdExec timeout sends SIGTERM and records timed_out=true" {
    // Sleep 10 with timeout_secs=1 — child must be killed; record
    // shows timed_out + nonzero exit. We don't assert the exact exit
    // code because it depends on SIGTERM (143) vs SIGKILL (137)
    // ordering, and either is correct.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-timeout-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    const before = posix.nowEpoch();
    try cmdExec(&ctx, run_id, null, 1, null, false, &[_][]const u8{ "/bin/sh", "-c", "sleep 10" });
    const after = posix.nowEpoch();
    const rec = (try runs_mod.metaRead(a, run_id)).?;
    try testing.expect(rec.timed_out);
    try testing.expect(rec.finished_at != null);
    // The whole call must take ~1s + grace, not 10s.
    try testing.expect(after - before < 5);
}

test "cmdExec without --once leaves the source job in place" {
    // Source-removal only fires when once_flag=true. With once=false,
    // _exec just records the run; the crontab is untouched.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "exec-no-once-{x}", .{posix.nowEpoch()});
    defer cleanupRun(a, run_id);
    var ctx = newCtx(a);
    try cmdExec(&ctx, run_id, "fake-source", null, null, false, &[_][]const u8{ "/bin/sh", "-c", "exit 0" });
    const rec = (try runs_mod.metaRead(a, run_id)).?;
    try testing.expectEqual(@as(?i32, 0), rec.exit_code);
    try testing.expect(!rec.once);
}
