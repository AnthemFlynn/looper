//! Declarative state convergence (v0.2 #2).
//!
//! `apply <spec.toml>` reads a list of `[[job]]` blocks and converges the
//! target's managed jobs to match: jobs in the spec but not the crontab
//! are added; jobs whose schedule or command differs are updated. Foreign
//! (non-`#looper#`) lines are untouched — `apply` is for managed state.
//!
//! `plan <spec.toml>` is the same comparison, but read-only: it emits a
//! unified diff (or JSON) and exits non-zero when the crontab differs
//! from the spec. Wraps `applyMutation` with `ctx.dry_run = true`.
//!
//! Removal-on-drift: not in v0.2 by design. The simplest safe convergence
//! is "spec adds and updates"; introducing deletion needs a guard
//! (`--prune` flag) so a spec that accidentally omits a job doesn't
//! silently uninstall it. v0.3 can decide; the script doesn't require it.
//!
//! Wrapper-refresh: `apply` does NOT refresh `wrapper_bin` on existing
//! jobs — only newly-added jobs pick up the current `posix.looperPath`.
//! If the operator moves the looper binary and re-runs `apply`, existing
//! wrapped jobs continue to invoke the stale path and cron-fires will
//! silently fail. To refresh, `rm` + re-`add` the affected jobs (or wait
//! for a future `apply --refresh-wrapper` in v0.3). This is intentional:
//! refreshing on every apply would mutate the crontab on no-op runs and
//! break idempotency for the (common) case where the binary is stable.
//!
//! Both commands route the final write through `core.applyMutation`, so
//! the backup-before-mutation invariant from CLAUDE.md is preserved.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const sched_mod = @import("../cron/schedule.zig");
const nlp = @import("../cron/nlp.zig");
const spec_mod = @import("../spec.zig");
const core = @import("core.zig");
const colors = @import("../ui/colors.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

pub const ApplyOpts = struct {
    /// Stamp `created_by` / `last_modified_by` on the converged jobs the
    /// same way `cmdAdd` does — `apply` is just a batch-mode `add` from
    /// the provenance point of view.
    as: ?[]const u8 = null,
};

/// Read the spec from disk + validate every schedule before any mutation.
/// Returns null on any I/O or parse failure (already emitted a diagnostic
/// and called ctx.fail). Centralizes the failure path so apply and plan
/// share identical "load + validate" semantics.
fn loadSpec(ctx: *Ctx, path: []const u8) ?spec_mod.Spec {
    const content = target_mod.readFileAll(ctx.a, path) catch |e| {
        posix.eprint("looper: cannot read spec '{s}': {s}\n", .{ path, @errorName(e) });
        ctx.fail(1);
        return null;
    };
    if (content.len == 0) {
        posix.eprint("looper: spec '{s}' is empty or unreadable\n", .{path});
        ctx.fail(1);
        return null;
    }
    var diag: ?[]const u8 = null;
    const spec = spec_mod.parse(ctx.a, content, &diag) catch |e| {
        if (diag) |d| posix.eprint("looper: spec error in '{s}': {s}\n", .{ path, d }) else posix.eprint("looper: spec error in '{s}': {s}\n", .{ path, @errorName(e) });
        ctx.fail(1);
        return null;
    };

    // Validate every schedule up-front. If any one job has a bad schedule
    // we refuse the whole apply — partial convergence is worse than a
    // clear "fix this and re-run" message.
    for (spec.jobs) |sj| {
        const cron = nlp.toCron(ctx.a, sj.schedule) orelse {
            posix.eprint("looper: spec job '{s}': couldn't read schedule '{s}'\n", .{ sj.id, sj.schedule });
            ctx.fail(1);
            return null;
        };
        _ = sched_mod.parseSchedule(cron) catch |e| {
            posix.eprint("looper: spec job '{s}': invalid schedule '{s}': {s}\n", .{ sj.id, cron, @errorName(e) });
            ctx.fail(1);
            return null;
        };
    }
    return spec;
}

/// Apply spec to crontab, returning the new content. Does not write —
/// caller routes through `applyMutation` so the backup-before-write
/// invariant holds. Wrap-by-default mirrors `cmdAdd`: every spec'd job
/// becomes a wrapped `_exec` line when a looper binary path is available,
/// so silent cron failure stays detectable for declarative installs too.
fn convergeContent(
    ctx: *Ctx,
    content: []const u8,
    spec: spec_mod.Spec,
    opts: ApplyOpts,
) ![]const u8 {
    var ct = try model.parseCrontab(ctx.a, content);
    const wrapper_bin = posix.looperPath(ctx.a);
    const now = posix.nowEpoch();

    for (spec.jobs) |sj| {
        // Re-canonicalize through nlp + parseSchedule so the schedule
        // stored in the crontab matches what cmdAdd would have written.
        // Without this, a spec saying "@daily" would round-trip cleanly
        // but a spec saying "every day at midnight" would diff against
        // the crontab on every plan/apply because the stored form is
        // canonical cron, not the user's English.
        const cron = nlp.toCron(ctx.a, sj.schedule) orelse {
            // Refactor guard: loadSpec already validated this schedule,
            // so this branch should be unreachable today. Surface the
            // bug loudly instead of `.?`-panicking if load/converge ever
            // split across a boundary that breaks the invariant.
            posix.eprint("looper: internal: spec schedule '{s}' reparsed to null after loadSpec validated\n", .{sj.schedule});
            return error.InternalScheduleReparse;
        };
        if (ct.findIndex(sj.id)) |i| {
            const j = &ct.items.items[i].job;
            // Schedule + command convergence. Only stamp last_modified_*
            // when something actually changed, so re-running an unchanged
            // spec doesn't bump timestamps and create spurious drift in
            // monitoring tools.
            const sched_changed = !std.mem.eql(u8, j.schedule, cron);
            const cmd_changed = !std.mem.eql(u8, j.command, sj.command);
            if (sched_changed) j.schedule = cron;
            if (cmd_changed) j.command = sj.command;
            j.enabled = true;
            if ((sched_changed or cmd_changed) and opts.as != null) {
                j.last_modified_by = opts.as;
                j.last_modified_at = now;
                if (j.created_by == null) {
                    j.created_by = opts.as;
                    j.created_at = now;
                }
            }
        } else {
            const wrap = wrapper_bin != null;
            try ct.items.append(ctx.a, .{ .job = .{
                .id = try ctx.a.dupe(u8, sj.id),
                .enabled = true,
                .schedule = cron,
                .command = try ctx.a.dupe(u8, sj.command),
                .capture = wrap,
                .wrapper_bin = wrapper_bin,
                .created_by = opts.as,
                .created_at = if (opts.as != null) now else null,
                .last_modified_by = opts.as,
                .last_modified_at = if (opts.as != null) now else null,
            } });
        }
    }
    return model.serialize(ctx.a, &ct);
}

pub fn cmdApply(ctx: *Ctx, t: Target, content: []const u8, spec_path: []const u8, opts: ApplyOpts) !void {
    const spec = loadSpec(ctx, spec_path) orelse return;
    const new_content = try convergeContent(ctx, content, spec, opts);
    const verb = try std.fmt.allocPrint(ctx.a, "applied spec '{s}' ({d} job(s))", .{ spec_path, spec.jobs.len });
    try core.applyMutation(ctx, t, content, new_content, verb);
}

pub fn cmdPlan(ctx: *Ctx, t: Target, content: []const u8, spec_path: []const u8, opts: ApplyOpts) !void {
    const spec = loadSpec(ctx, spec_path) orelse return;
    const new_content = try convergeContent(ctx, content, spec, opts);
    const same = std.mem.eql(u8, content, new_content);
    // `plan` is dry-run by definition. Force ctx.dry_run so applyMutation
    // emits the diff path (text or JSON depending on ctx.json) without
    // writing. Restore afterwards so a caller running multiple commands
    // doesn't get sticky dry_run state.
    const prev_dry = ctx.dry_run;
    ctx.dry_run = true;
    defer ctx.dry_run = prev_dry;
    const verb = try std.fmt.allocPrint(ctx.a, "plan '{s}'", .{spec_path});
    try core.applyMutation(ctx, t, content, new_content, verb);
    if (!same) {
        // Non-zero exit signals drift to scripts. Exit code 2 is the
        // convention from `terraform plan -detailed-exitcode` and similar
        // tools — distinguishable from "1 = error" so CI can branch on it.
        ctx.fail(2);
    }
}

const testing = std.testing;

fn tmpTarget(a: std.mem.Allocator) !Target {
    const path = try std.fmt.allocPrint(a, "/tmp/looper-apply-test-{x}.crontab", .{posix.nowEpoch()});
    return Target{ .kind = .file, .path = path };
}

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

fn writeSpec(a: std.mem.Allocator, contents: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "/tmp/looper-spec-test-{x}.toml", .{posix.nowEpoch()});
    try target_mod.writeFileAll(a, path, contents);
    return path;
}

test "cmdApply creates jobs from spec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    const sp = try writeSpec(a,
        \\[[job]]
        \\id = "spec-a"
        \\schedule = "0 3 * * *"
        \\command = "/usr/bin/true"
        \\
    );
    defer _ = posix.c.unlink((a.dupeZ(u8, sp) catch unreachable).ptr);
    try cmdApply(&ctx, tgt, "", sp, .{});
    const got = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, got, "#looper# id=spec-a") != null);
    try testing.expect(std.mem.indexOf(u8, got, "0 3 * * *") != null);
}

test "cmdApply is idempotent (no change on second run)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    const sp = try writeSpec(a,
        \\[[job]]
        \\id = "x"
        \\schedule = "@daily"
        \\command = "/bin/true"
        \\
    );
    defer _ = posix.c.unlink((a.dupeZ(u8, sp) catch unreachable).ptr);
    try cmdApply(&ctx, tgt, "", sp, .{});
    const c1 = try target_mod.readFileAll(a, tgt.path);
    try cmdApply(&ctx, tgt, c1, sp, .{});
    const c2 = try target_mod.readFileAll(a, tgt.path);
    try testing.expectEqualStrings(c1, c2);
}

test "cmdPlan exits 0 on convergence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    const sp = try writeSpec(a,
        \\[[job]]
        \\id = "x"
        \\schedule = "@daily"
        \\command = "/bin/true"
        \\
    );
    defer _ = posix.c.unlink((a.dupeZ(u8, sp) catch unreachable).ptr);
    try cmdApply(&ctx, tgt, "", sp, .{});
    const c1 = try target_mod.readFileAll(a, tgt.path);
    ctx.exit_code = 0;
    try cmdPlan(&ctx, tgt, c1, sp, .{});
    try testing.expectEqual(@as(u8, 0), ctx.exit_code);
}

test "cmdPlan exits 2 on drift" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    const sp = try writeSpec(a,
        \\[[job]]
        \\id = "x"
        \\schedule = "@daily"
        \\command = "/bin/true"
        \\[[job]]
        \\id = "y"
        \\schedule = "@hourly"
        \\command = "/bin/false"
        \\
    );
    defer _ = posix.c.unlink((a.dupeZ(u8, sp) catch unreachable).ptr);
    // Empty crontab vs two-job spec — drift expected.
    try cmdPlan(&ctx, tgt, "", sp, .{});
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdApply updates schedule on existing job (in-place)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const tgt = try tmpTarget(a);
    defer _ = posix.c.unlink((a.dupeZ(u8, tgt.path) catch unreachable).ptr);
    const sp1 = try writeSpec(a,
        \\[[job]]
        \\id = "x"
        \\schedule = "0 3 * * *"
        \\command = "/bin/true"
    );
    defer _ = posix.c.unlink((a.dupeZ(u8, sp1) catch unreachable).ptr);
    try cmdApply(&ctx, tgt, "", sp1, .{});
    const c1 = try target_mod.readFileAll(a, tgt.path);
    const sp2 = try writeSpec(a,
        \\[[job]]
        \\id = "x"
        \\schedule = "0 4 * * *"
        \\command = "/bin/true"
    );
    defer _ = posix.c.unlink((a.dupeZ(u8, sp2) catch unreachable).ptr);
    try cmdApply(&ctx, tgt, c1, sp2, .{});
    const c2 = try target_mod.readFileAll(a, tgt.path);
    try testing.expect(std.mem.indexOf(u8, c2, "0 4 * * *") != null);
    try testing.expect(std.mem.indexOf(u8, c2, "0 3 * * *") == null);
}
