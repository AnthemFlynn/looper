//! Crontab mutators: add, edit, rm, enable/disable. Every one routes
//! its write through `core.applyMutation`; nothing here calls
//! `writeCrontab` directly.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const sched_mod = @import("../cron/schedule.zig");
const humanize = @import("../cron/humanize.zig");
const nlp = @import("../cron/nlp.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");
const core = @import("core.zig");
const preflight = @import("preflight.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

/// Optional flags for `cmdAdd`. Bundled into a struct so adding a new
/// flag (--capture, future --once-by-default, etc.) doesn't break every
/// caller's positional argument list.
pub const AddOpts = struct {
    /// Run the binary-reachability preflight (warns when the command's
    /// first executable token isn't on PATH for the target). Non-blocking;
    /// the add proceeds either way.
    check_command: bool = false,
    /// Wrap the cron payload in `looper _exec` so each fire writes a
    /// run record under state_dir/runs/. The looper binary path is
    /// resolved at this call (posix.looperPath) and embedded in the
    /// marker as `wrapper_bin=...` so the job survives binary moves
    /// only insofar as the captured path stays valid. When updating an
    /// existing job, --capture only sets capture=true; it does not
    /// unset capture (use rm + re-add for that).
    capture: bool = false,
    /// `--no-wrap`: skip the wrap-by-default behavior introduced in v0.1.
    /// When false (default), `add` wraps the cron payload through `_exec`
    /// so silent cron failure becomes detectable. When true, the cron
    /// payload is the bare command. File targets always honor wrap-by-
    /// default only when `posix.looperPath` resolves; otherwise the add
    /// silently degrades to bare so tests on platforms without a stable
    /// self-path still work.
    no_wrap: bool = false,
    /// `--as <principal>`: the actor performing this add. Sets the job's
    /// `created_by` for new jobs and `last_modified_by` for existing
    /// ones. Null when the user neither supplied `--as` nor exported
    /// `LOOPER_AS` — provenance fields stay unset in that case.
    as: ?[]const u8 = null,
};

pub fn cmdAdd(ctx: *Ctx, t: Target, content: []const u8, schedule: []const u8, command: []const u8, want_id: ?[]const u8, opts: AddOpts) !void {
    const cron = nlp.toCron(ctx.a, schedule) orelse {
        posix.eprint("looper: couldn't read schedule '{s}'\n", .{schedule});
        posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
        posix.eprint("  preview with: looper explain '{s}'\n", .{schedule});
        ctx.fail(1);
        return;
    };
    _ = sched_mod.parseSchedule(cron) catch |e| {
        posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ cron, @errorName(e) });
        ctx.fail(1);
        return;
    };
    if (!std.mem.eql(u8, cron, schedule))
        ctx.emit("{s}interpreted{s} \"{s}\" as {s}{s}{s}  ({s})\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET), schedule, ctx.k(colors.BOLD), cron, ctx.k(colors.RESET), humanize.humanize(ctx.a, cron) });
    // Opt-in preflight. Not blocking: cron failures usually surface as
    // silent "no such file or directory" in the mail spool, which is
    // exactly what we want to head off — surface it now, still add the
    // job. Suppressed under --quiet (diagnostic noise) and --json (would
    // pollute the structured output on stdout).
    if (opts.check_command and !ctx.quiet and !ctx.json) {
        if (preflight.extractBinary(command)) |bin| {
            switch (preflight.commandReachable(ctx.a, t, bin)) {
                .missing => ctx.emit(
                    "{s}!{s} command {s}'{s}'{s} not found on {s} — cron may fail to run (PATH under cron is minimal; consider an absolute path)\n",
                    .{ ctx.k(colors.YELLOW), ctx.k(colors.RESET), ctx.k(colors.BOLD), bin, ctx.k(colors.RESET), t.label(ctx.a) },
                ),
                .found, .skipped => {},
            }
        }
    }
    // Wrap-by-default (v0.1): unless --no-wrap, every `add` produces a
    // captured-and-wrapped cron line so silent cron failure becomes
    // detectable. Existing callers that pass `.capture = true` are still
    // honored (legacy --capture). The two flags are equivalent in this
    // model: wrap implies capture (both names map to the same wrapped
    // _exec payload). Resolution of the looper binary path is best-
    // effort; on platforms without a stable self-path, we degrade to
    // bare so tests stay portable.
    const want_wrap = !opts.no_wrap or opts.capture;
    var wrapper_bin: ?[]const u8 = null;
    var wrap_effective = false;
    if (want_wrap) {
        wrapper_bin = posix.looperPath(ctx.a);
        wrap_effective = wrapper_bin != null;
        if (opts.capture and wrapper_bin == null) {
            // Explicit --capture should fail loudly (legacy contract);
            // silent degrade is only acceptable for the new default path.
            posix.eprint("looper: --capture needs the looper binary path, but this platform doesn't expose one (Linux + macOS only in v1)\n", .{});
            ctx.fail(1);
            return;
        }
    }
    const now = posix.nowEpoch();
    var ct = try model.parseCrontab(ctx.a, content);
    const id = want_id orelse blk: {
        for (ct.items.items) |it| switch (it) {
            .job => |j| if (!j.foreign and std.mem.eql(u8, j.schedule, cron) and std.mem.eql(u8, j.command, command)) break :blk j.id,
            else => {},
        };
        break :blk display.slugUnique(ctx.a, &ct, command);
    };
    if (ct.findIndex(id)) |i| {
        ct.items.items[i].job.schedule = cron;
        ct.items.items[i].job.command = command;
        ct.items.items[i].job.enabled = true;
        // Capture is sticky on update (wrap-by-default or legacy
        // --capture only sets, never unsets). To remove capture, rm +
        // re-add with --no-wrap. Documented in AddOpts.no_wrap.
        if (wrap_effective) {
            ct.items.items[i].job.capture = true;
            ct.items.items[i].job.wrapper_bin = wrapper_bin;
        }
        if (opts.as) |actor| {
            ct.items.items[i].job.last_modified_by = actor;
            ct.items.items[i].job.last_modified_at = now;
            // Backfill created_by on jobs that pre-date provenance —
            // we know an actor is touching it now, so attribution is
            // strictly better than null forever.
            if (ct.items.items[i].job.created_by == null) {
                ct.items.items[i].job.created_by = actor;
                ct.items.items[i].job.created_at = now;
            }
        }
    } else try ct.items.append(ctx.a, .{ .job = .{
        .id = id,
        .enabled = true,
        .schedule = cron,
        .command = command,
        .capture = wrap_effective,
        .wrapper_bin = wrapper_bin,
        .created_by = opts.as,
        .created_at = if (opts.as != null) now else null,
        .last_modified_by = opts.as,
        .last_modified_at = if (opts.as != null) now else null,
    } });
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "set job '{s}'", .{id});
    try core.applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdToggle(ctx: *Ctx, t: Target, content: []const u8, ids: [][]const u8, enable: bool) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var touched: usize = 0;
    for (ids) |id| {
        if (ct.findIndex(id)) |i| {
            ct.items.items[i].job.enabled = enable;
            touched += 1;
        } else {
            posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
            ctx.fail(1);
        }
    }
    if (touched == 0) return;
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "{s} {d} job(s)", .{ if (enable) "enabled" else "disabled", touched });
    try core.applyMutation(ctx, t, content, new_content, verb);
}

/// Options for `cmdEdit`. Parallel to `AddOpts` — `as` carries the
/// principal performing the edit, which updates `last_modified_by` and
/// backfills `created_by` if it was null (same pattern as cmdAdd's
/// update branch).
pub const EditOpts = struct {
    as: ?[]const u8 = null,
};

pub fn cmdEdit(ctx: *Ctx, t: Target, content: []const u8, id: []const u8, new_schedule: ?[]const u8, new_command: ?[]const u8, opts: EditOpts) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    const idx = ct.findIndex(id) orelse {
        posix.eprint("looper: no managed job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        posix.eprint("  (foreign jobs must be adopted with 'looper import' before editing)\n", .{});
        ctx.fail(1);
        return;
    };
    if (new_schedule) |raw| {
        // Same NLP + validation chain as cmdAdd: surface the same errors
        // and the same "interpreted as" disclosure so `edit` behaves
        // identically to `add` for the schedule-update path.
        const cron = nlp.toCron(ctx.a, raw) orelse {
            posix.eprint("looper: couldn't read schedule '{s}'\n", .{raw});
            posix.eprint("  use cron (\"*/15 9-17 * * 1-5\") or plain English (\"every weekday at 9am\")\n", .{});
            posix.eprint("  preview with: looper explain '{s}'\n", .{raw});
            ctx.fail(1);
            return;
        };
        _ = sched_mod.parseSchedule(cron) catch |e| {
            posix.eprint("looper: invalid schedule '{s}': {s}\n", .{ cron, @errorName(e) });
            ctx.fail(1);
            return;
        };
        if (!std.mem.eql(u8, cron, raw))
            ctx.emit("{s}interpreted{s} \"{s}\" as {s}{s}{s}  ({s})\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET), raw, ctx.k(colors.BOLD), cron, ctx.k(colors.RESET), humanize.humanize(ctx.a, cron) });
        ct.items.items[idx].job.schedule = cron;
    }
    if (new_command) |cmd| ct.items.items[idx].job.command = cmd;
    if (opts.as) |actor| {
        // Mirrors the update branch in cmdAdd: stamp last_modified_*
        // unconditionally, backfill created_* when the job pre-dates
        // provenance so attribution is strictly better than null.
        const now = posix.nowEpoch();
        ct.items.items[idx].job.last_modified_by = actor;
        ct.items.items[idx].job.last_modified_at = now;
        if (ct.items.items[idx].job.created_by == null) {
            ct.items.items[idx].job.created_by = actor;
            ct.items.items[idx].job.created_at = now;
        }
    }
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "edited '{s}'", .{id});
    try core.applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdRm(ctx: *Ctx, t: Target, content: []const u8, ids: [][]const u8) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var rm: std.ArrayList(usize) = .empty;
    for (ids) |id| {
        if (ct.findIndex(id)) |i| {
            try rm.append(ctx.a, i);
            continue;
        }
        if (id.len >= 2 and id[0] == 'f' and model.allDigits(id[1..])) {
            const n = std.fmt.parseInt(usize, id[1..], 10) catch 0;
            if (ct.findForeign(n)) |i| {
                try rm.append(ctx.a, i);
                continue;
            }
        }
        posix.eprint("looper: no job '{s}' on {s}\n", .{ id, t.label(ctx.a) });
        ctx.fail(1);
    }
    if (rm.items.len == 0) return;
    if (!display.confirm(ctx, "Remove {d} job(s) from {s}?", .{ rm.items.len, t.label(ctx.a) })) {
        ctx.emit("aborted\n", .{});
        return;
    }
    var keep: std.ArrayList(model.Item) = .empty;
    outer: for (ct.items.items, 0..) |it, idx| {
        for (rm.items) |ri| if (ri == idx) continue :outer;
        try keep.append(ctx.a, it);
    }
    ct.items = keep;
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "removed {d} job(s)", .{rm.items.len});
    try core.applyMutation(ctx, t, content, new_content, verb);
}

const testing = std.testing;

fn tmpTarget(a: std.mem.Allocator) !Target {
    const path = try std.fmt.allocPrint(a, "/tmp/looper-mutate-test-{x}.crontab", .{posix.nowEpoch()});
    return Target{ .kind = .file, .path = path };
}

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

test "cmdAdd then serialize contains a managed job" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    // .no_wrap pins the bare-cron payload these byte-level assertions
    // were written against. Wrap-by-default (v0.1) replaces this layout
    // with a `_exec` wrapper line; the wrap-default contract has its
    // own test below.
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo", .{ .no_wrap = true });
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "#looper# id=demo enabled=1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * * /bin/echo hi") != null);
}

test "cmdToggle disables a job by commenting payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo", .{ .no_wrap = true });
    const after_add = try target_mod.readFileAll(a, tgt.path);
    var ids = [_][]const u8{"demo"};
    try cmdToggle(&ctx, tgt, after_add, ids[0..], false);
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "enabled=0") != null);
    try testing.expect(std.mem.indexOf(u8, got, "# 0 3 * * * /bin/echo hi") != null);
}

test "cmdAdd is idempotent by id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo first", "demo", .{ .no_wrap = true });
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdAdd(&ctx, tgt, c1, "0 4 * * *", "/bin/echo second", "demo", .{ .no_wrap = true });
    const c2 = try target_mod.readFileAll(a, tgt.path);
    // exactly one marker line — second add updated in place
    var marker_count: usize = 0;
    var it = std.mem.splitScalar(u8, c2, '\n');
    while (it.next()) |line| if (std.mem.startsWith(u8, line, "#looper#")) {
        marker_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), marker_count);
    try testing.expect(std.mem.indexOf(u8, c2, "0 4 * * * /bin/echo second") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "first") == null);
}

test "cmdEdit --schedule preserves command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo original", "demo", .{ .no_wrap = true });
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "0 4 * * *", null, .{});
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "0 4 * * * /bin/echo original") != null);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * *") == null);
}

test "cmdEdit --command preserves schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo original", "demo", .{ .no_wrap = true });
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", null, "/bin/echo updated", .{});
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * * /bin/echo updated") != null);
    try testing.expect(std.mem.indexOf(u8, got, "original") == null);
}

test "cmdEdit both flags update both fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{ .no_wrap = true });
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "@hourly", "/bin/echo b", .{});
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "@hourly /bin/echo b") != null);
}

test "cmdEdit rejects unknown id with exit 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    try cmdEdit(&ctx, tgt, "", "no-such-job", "@daily", null, .{});
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdEdit rejects foreign job (no marker) with exit 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    // Foreign job — no `#looper#` marker, so findIndex returns null
    // even though it's a real cron line.
    const foreign = "0 5 * * * /opt/legacy/job.sh\n";
    try cmdEdit(&ctx, tgt, foreign, "legacy", "@daily", null, .{});
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdEdit rejects invalid schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{});
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "not a real schedule and not English either", null, .{});
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
    // File content must be unchanged after a rejected edit.
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expectEqualStrings(after_add, got);
}

test "cmdEdit accepts an @macro schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{ .no_wrap = true });
    const after_add = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, after_add, "demo", "@daily", null, .{});
    const got = try target_mod.readFileAll(a, tgt.path);
    // nlp passes already-valid cron (including @macros) through unchanged.
    try testing.expect(std.mem.indexOf(u8, got, "@daily /bin/echo a") != null);
}

test "cmdAdd local+missing+check_command emits the yellow ! warning" {
    // dry_run=true keeps applyMutation from invoking `crontab` for the
    // local target — the probe still runs (it doesn't depend on the
    // dry-run flag) and the warning emits to the buffer.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/almost/certainly/not/here", "demo", .{ .check_command = true });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found on local") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "/zzz/almost/certainly/not/here") != null);
}

test "cmdAdd local+found+check_command emits NO warning (binary exists)" {
    // Positive control: `/bin/sh` exists everywhere this test would
    // run, so the probe returns .found and the warning path is silent.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/sh -c 'echo hi'", "demo", .{ .check_command = true });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}

test "cmdAdd local+missing+check_command under --json suppresses the warning" {
    // The "! command not found" line is non-JSON text; under --json it
    // would corrupt structured stdout, so it must be silenced. We use
    // a .local target so the probe actually runs and returns .missing
    // — under --json + .file the test would pass trivially.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/almost/certainly/not/here", "demo", .{ .check_command = true });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}

test "cmdAdd local+missing+check_command under --quiet suppresses the warning" {
    // --quiet means "diagnostic output off"; the preflight is a
    // diagnostic, not a hard error, so it goes silent too.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.quiet = true;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/almost/certainly/not/here", "demo", .{ .check_command = true });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}

test "cmdAdd --capture marks the job and embeds wrapper_bin" {
    // End-to-end check: --capture goes in, the resulting crontab has
    // a marker with capture=1 + wrapper_bin pointing at the live looper
    // binary, and the cron payload is the synthesized wrapper line.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/usr/local/bin/backup.sh", "demo", .{ .capture = true });
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "capture=1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "wrapper_bin=") != null);
    // Cron payload must contain the _exec sentinel + shell-quoted inner.
    try testing.expect(std.mem.indexOf(u8, got, "_exec --source-id=demo") != null);
    try testing.expect(std.mem.indexOf(u8, got, " -- /bin/sh -c '/usr/local/bin/backup.sh'") != null);
}

test "cmdAdd --capture round-trips through parseCrontab unchanged" {
    // After cmdAdd writes a wrapped job, re-reading the file must
    // surface the user's INNER command on Job.command (not the wrapper).
    // This is the DX promise: looper ls shows what you typed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/usr/local/bin/backup.sh --verbose", "demo", .{ .capture = true });
    const got = try target_mod.readFileAll(a, tgt.path);
    const ct = try model.parseCrontab(a, got);
    var found = false;
    for (ct.items.items) |it| switch (it) {
        .job => |j| if (std.mem.eql(u8, j.id, "demo")) {
            try testing.expectEqualStrings("/usr/local/bin/backup.sh --verbose", j.command);
            try testing.expect(j.capture);
            try testing.expect(j.wrapper_bin != null);
            found = true;
        },
        else => {},
    };
    try testing.expect(found);
}

test "cmdAdd --no-wrap leaves capture=0 (legacy bare-cron path)" {
    // Under wrap-by-default (v0.1), plain `add` produces a wrapped
    // line. The escape hatch is `--no-wrap`, exercised here to pin
    // the bare-cron payload contract.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo", "demo", .{ .no_wrap = true });
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "capture=1") == null);
    try testing.expect(std.mem.indexOf(u8, got, "wrapper_bin=") == null);
    try testing.expect(std.mem.indexOf(u8, got, "_exec") == null);
}

test "cmdAdd wrap-by-default (no flags) produces a wrapped line" {
    // The new v0.1 contract: plain `add` with no flags wraps the
    // payload so silent cron failure becomes detectable. Pinned here
    // alongside the explicit --no-wrap test above.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo hi", "demo", .{});
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "capture=1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "_exec --source-id=demo") != null);
}

test "cmdAdd --capture preserves capture when re-adding without --capture" {
    // Sticky behavior: once a job is capture-enabled, plain `looper add`
    // doesn't silently strip capture. To remove, rm + re-add (documented
    // contract on AddOpts.capture).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{ .capture = true });
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdAdd(&ctx, tgt, c1, "0 4 * * *", "/bin/echo b", "demo", .{});
    const c2 = try target_mod.readFileAll(a, tgt.path);
    // Schedule updated (4 instead of 3), command updated, but capture
    // still set. wrapper_bin also preserved.
    try testing.expect(std.mem.indexOf(u8, c2, "capture=1") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "0 4 * * *") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "/bin/echo b") != null);
}

test "cmdEdit with --as updates last_modified_by + last_modified_at" {
    // MEDIUM#2 regression: editing a job with --as must stamp the
    // last_modified_* fields so the audit trail tracks who changed what.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{ .as = "agent-a" });
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, c1, "demo", "0 4 * * *", null, .{ .as = "agent-b" });
    const c2 = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, c2, "created_by=agent-a") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "last_modified_by=agent-b") != null);
}

test "cmdEdit with --as backfills created_by when null" {
    // A job added before provenance shipped (created_by=null) gets
    // attributed to whoever first touches it via edit — strictly
    // better than null forever.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    // Seed a legacy-style job: no --as, no_wrap so we can read it back
    // cleanly without the capture wrapper noise.
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{ .no_wrap = true });
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, c1, "created_by=") == null);
    try cmdEdit(&ctx, tgt, c1, "demo", null, "/bin/echo b", .{ .as = "first-editor" });
    const c2 = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, c2, "created_by=first-editor") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "last_modified_by=first-editor") != null);
}

test "cmdEdit without --as preserves existing provenance" {
    // Editing without supplying --as must not blank out the existing
    // created_by/last_modified_by attribution.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/bin/echo a", "demo", .{ .as = "agent-a" });
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdEdit(&ctx, tgt, c1, "demo", "0 4 * * *", null, .{});
    const c2 = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, c2, "created_by=agent-a") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "last_modified_by=agent-a") != null);
}

test "cmdAdd check_command=false does not probe at all" {
    // Default path: even with a missing binary, no warning fires when
    // the user didn't opt in. Pins the "no behaviour change without
    // the flag" contract from the commit message.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.color = false;
    ctx.dry_run = true;
    const tgt: Target = .{ .kind = .local };
    try cmdAdd(&ctx, tgt, "", "0 3 * * *", "/zzz/missing", "demo", .{});
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "not found") == null);
}
