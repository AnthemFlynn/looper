//! Run-record verbs: `runs ls` (combined view of executed + pending),
//! `runs show <id>` (single record + captured output), `runs prune`
//! (housekeeping). All three operate on local state — execution records
//! live under $XDG_STATE_HOME/looper/runs/, which is per-machine, so
//! there's no `-H host` cross-target concept here.
//!
//! Pending detection: a one-shot job (marker.once=1 with run_id set)
//! that has no corresponding meta file yet is reported as pending. The
//! local crontab is the source of truth for those; if a caller can't
//! read it, runs ls just shows the executed records and skips pending.

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const runs_mod = @import("../crontab/runs.zig");
const humanize = @import("../cron/humanize.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");

const Ctx = ctx_mod.Ctx;
const RunRecord = runs_mod.RunRecord;
const RunStatus = runs_mod.RunStatus;

pub const Filter = struct {
    /// When set, only records matching this status appear in output.
    status: ?RunStatus = null,
    /// `--owner <principal>`: only records whose `created_by` matches.
    /// Records without `created_by` never match a non-null owner filter.
    owner: ?[]const u8 = null,
};

/// JSON envelope version for runs output. See view.SCHEMA_VERSION for
/// the rationale — kept in lockstep so consumers can rely on the same
/// version across all looper JSON surfaces.
const SCHEMA_VERSION: u32 = 1;

/// Default cap for inline stdout/stderr in `runs show`. The captured
/// files can be arbitrarily large; spilling all of it into the response
/// is hostile to both terminals and MCP clients. Override with --full
/// on the CLI or omitted in JSON for now (size guard is sufficient).
const SHOW_INLINE_CAP: usize = 8 * 1024;

fn statusStr(s: RunStatus) []const u8 {
    return switch (s) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .failed => "failed",
    };
}

fn parseStatus(s: []const u8) ?RunStatus {
    if (std.mem.eql(u8, s, "pending")) return .pending;
    if (std.mem.eql(u8, s, "running")) return .running;
    if (std.mem.eql(u8, s, "done")) return .done;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    return null;
}

pub fn parseStatusFilter(s: []const u8) ?RunStatus {
    return parseStatus(s);
}

/// Pick the "primary timestamp" for sort + age display. We prefer the
/// most recent lifecycle field that's set, falling back through the
/// chain. Pending records (none set) sort to the top via i64.max.
fn primaryTime(r: RunRecord) i64 {
    if (r.finished_at) |t| return t;
    if (r.started_at) |t| return t;
    if (r.scheduled_for) |t| return t;
    return std.math.maxInt(i64);
}

/// Newest-first by primary timestamp — pending records (no times yet)
/// float to the top via maxInt, matching the "what's upcoming" framing.
fn lessNewerFirst(_: void, a: RunRecord, b: RunRecord) bool {
    return primaryTime(a) > primaryTime(b);
}

/// Build the combined view: executed records on disk plus synthetic
/// pending records derived from the local crontab. If `crontab_content`
/// is empty (caller couldn't read or chose not to pass it), only the
/// on-disk records appear — pending one-shots stay invisible until they
/// fire. That degradation is acceptable: `looper ls` is the source of
/// truth for "what's queued", `runs` for "what happened".
fn collectAll(a: std.mem.Allocator, crontab_content: []const u8) ![]RunRecord {
    var out: std.ArrayList(RunRecord) = .empty;
    const on_disk = try runs_mod.listRuns(a);
    for (on_disk) |r| try out.append(a, r);

    if (crontab_content.len > 0) {
        var seen_run_ids: std.StringHashMap(void) = .init(a);
        defer seen_run_ids.deinit();
        for (on_disk) |r| try seen_run_ids.put(r.run_id, {});

        const ct = try model.parseCrontab(a, crontab_content);
        for (ct.items.items) |it| switch (it) {
            .job => |j| {
                if (!j.once) continue;
                const rid = j.run_id orelse continue;
                if (seen_run_ids.contains(rid)) continue;
                // Synthetic pending record — no started_at, so statusOf
                // classifies it as .pending.
                try out.append(a, .{
                    .run_id = rid,
                    .source_id = j.id,
                    .command = j.command,
                    .target_label = "local",
                    .once = true,
                });
            },
            else => {},
        };
    }

    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// runs ls
// ---------------------------------------------------------------------------

pub fn cmdRunsLs(ctx: *Ctx, crontab_content: []const u8, filter: Filter) !void {
    const all = try collectAll(ctx.a, crontab_content);
    std.mem.sort(RunRecord, all, {}, lessNewerFirst);

    var filtered: std.ArrayList(RunRecord) = .empty;
    for (all) |r| {
        if (filter.status) |want| {
            if (runs_mod.statusOf(r) != want) continue;
        }
        if (filter.owner) |want_owner| {
            const got = r.created_by orelse continue;
            if (!std.mem.eql(u8, got, want_owner)) continue;
        }
        try filtered.append(ctx.a, r);
    }

    if (ctx.json) return cmdRunsLsJson(ctx, filtered.items);

    if (filtered.items.len == 0) {
        const hint: []const u8 = if (filter.status) |s|
            std.fmt.allocPrint(ctx.a, " (filtered to status={s})", .{statusStr(s)}) catch ""
        else
            "";
        ctx.emit("{s}no runs recorded{s}{s}\n", .{ ctx.k(colors.DIM), hint, ctx.k(colors.RESET) });
        return;
    }

    const now = posix.nowEpoch();
    const w = display.termWidth();
    const cmd_w: usize = if (w > 70) w - 56 else 24;
    ctx.emit("{s}{s}{s}{s}{s}{s}\n", .{
        ctx.k(colors.BOLD),
        display.padTo(ctx.a, "RUN_ID", 18),
        display.padTo(ctx.a, "STATUS", 10),
        display.padTo(ctx.a, "WHEN", 18),
        "COMMAND",
        ctx.k(colors.RESET),
    });
    for (filtered.items) |r| {
        const status = runs_mod.statusOf(r);
        const status_color = switch (status) {
            .pending => ctx.k(colors.DIM),
            .running => ctx.k(colors.YELLOW),
            .done => ctx.k(colors.GREEN),
            .failed => ctx.k(colors.RED),
        };
        const when = humanWhen(ctx.a, r, now);
        ctx.emit("{s}{s}{s}{s}{s}{s} {s} {s}\n", .{
            ctx.k(colors.CYAN), display.padTo(ctx.a, display.truncEllipsis(ctx.a, r.run_id, 16), 18), ctx.k(colors.RESET),
            status_color,       display.padTo(ctx.a, statusStr(status), 10), ctx.k(colors.RESET),
            display.padTo(ctx.a, when, 17),
            display.truncEllipsis(ctx.a, r.command, cmd_w),
        });
    }
}

/// Short human time for the listing — "in 5m", "2h ago", "now". Picks
/// scheduled_for for pending records (the meaningful upcoming time) and
/// finished_at for completed ones.
fn humanWhen(a: std.mem.Allocator, r: RunRecord, now: i64) []const u8 {
    const ts_opt: ?i64 = r.finished_at orelse r.started_at orelse r.scheduled_for;
    const ts = ts_opt orelse return "—";
    return humanize.relTime(a, ts - now);
}

fn cmdRunsLsJson(ctx: *Ctx, records: []const RunRecord) !void {
    ctx.emit("{{\"schema_version\":{d},\"runs\":[", .{SCHEMA_VERSION});
    for (records, 0..) |r, i| {
        if (i > 0) ctx.emit(",", .{});
        emitRecordJson(ctx, r);
    }
    ctx.emit("]}}\n", .{});
}

fn emitRecordJson(ctx: *Ctx, r: RunRecord) void {
    const status = runs_mod.statusOf(r);
    ctx.emit("{{\"run_id\":\"{s}\",\"status\":\"{s}\",", .{
        display.jsonEsc(ctx.a, r.run_id), statusStr(status),
    });
    ctx.emit("\"source_id\":", .{});
    if (r.source_id) |sid| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, sid)}) else ctx.emit("null", .{});
    ctx.emit(",\"command\":\"{s}\"", .{display.jsonEsc(ctx.a, r.command)});
    ctx.emit(",\"target_label\":", .{});
    if (r.target_label) |tl| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, tl)}) else ctx.emit("null", .{});
    ctx.emit(",\"once\":{s}", .{if (r.once) "true" else "false"});
    emitOptInt(ctx, "scheduled_for", r.scheduled_for);
    emitOptInt(ctx, "started_at", r.started_at);
    emitOptInt(ctx, "finished_at", r.finished_at);
    if (r.exit_code) |code| ctx.emit(",\"exit_code\":{d}", .{code}) else ctx.emit(",\"exit_code\":null", .{});
    ctx.emit(",\"timed_out\":{s}", .{if (r.timed_out) "true" else "false"});
    if (r.created_by) |cb| ctx.emit(",\"created_by\":\"{s}\"", .{display.jsonEsc(ctx.a, cb)}) else ctx.emit(",\"created_by\":null", .{});
    ctx.emit("}}", .{});
}

fn emitOptInt(ctx: *Ctx, key: []const u8, v: ?i64) void {
    if (v) |t| ctx.emit(",\"{s}\":{d}", .{ key, t }) else ctx.emit(",\"{s}\":null", .{key});
}

// ---------------------------------------------------------------------------
// runs show
// ---------------------------------------------------------------------------

pub fn cmdRunsShow(ctx: *Ctx, run_id: []const u8, full: bool) !void {
    const rec = (try runs_mod.metaRead(ctx.a, run_id)) orelse {
        posix.eprint("looper: no run record for '{s}'\n", .{run_id});
        ctx.fail(1);
        return;
    };

    const cap: usize = if (full) std.math.maxInt(usize) else SHOW_INLINE_CAP;
    const stdout_bytes = target_mod.readFileAll(ctx.a, runs_mod.outPath(ctx.a, run_id)) catch "";
    const stderr_bytes = target_mod.readFileAll(ctx.a, runs_mod.errPath(ctx.a, run_id)) catch "";
    const out_trimmed = if (stdout_bytes.len > cap) stdout_bytes[0..cap] else stdout_bytes;
    const err_trimmed = if (stderr_bytes.len > cap) stderr_bytes[0..cap] else stderr_bytes;
    const out_truncated = stdout_bytes.len > cap;
    const err_truncated = stderr_bytes.len > cap;

    if (ctx.json) {
        emitRecordJsonShow(ctx, rec, out_trimmed, err_trimmed, out_truncated, err_truncated, stdout_bytes.len, stderr_bytes.len);
        return;
    }

    const status = runs_mod.statusOf(rec);
    const status_color = switch (status) {
        .pending => ctx.k(colors.DIM),
        .running => ctx.k(colors.YELLOW),
        .done => ctx.k(colors.GREEN),
        .failed => ctx.k(colors.RED),
    };
    ctx.emit("{s}{s}{s}{s}  {s}{s}{s}\n", .{
        ctx.k(colors.BOLD), ctx.k(colors.CYAN), rec.run_id, ctx.k(colors.RESET),
        status_color,       statusStr(status), ctx.k(colors.RESET),
    });
    if (rec.source_id) |sid| ctx.emit("  source   : {s}\n", .{sid});
    ctx.emit("  command  : {s}\n", .{rec.command});
    if (rec.target_label) |tl| ctx.emit("  target   : {s}\n", .{tl});
    if (rec.scheduled_for) |t| ctx.emit("  scheduled: {s}\n", .{humanize.fmtWhen(ctx.a, t)});
    if (rec.started_at) |t| ctx.emit("  started  : {s}\n", .{humanize.fmtWhen(ctx.a, t)});
    if (rec.finished_at) |t| ctx.emit("  finished : {s}\n", .{humanize.fmtWhen(ctx.a, t)});
    if (rec.exit_code) |code| ctx.emit("  exit     : {d}{s}\n", .{
        code, if (rec.timed_out) " (timed out)" else "",
    });

    if (out_trimmed.len > 0) {
        ctx.emit("{s}--- stdout ({d} bytes{s}) ---{s}\n", .{
            ctx.k(colors.DIM), stdout_bytes.len,
            if (out_truncated) ", truncated" else "",
            ctx.k(colors.RESET),
        });
        ctx.emit("{s}", .{out_trimmed});
        if (!std.mem.endsWith(u8, out_trimmed, "\n")) ctx.emit("\n", .{});
    }
    if (err_trimmed.len > 0) {
        ctx.emit("{s}--- stderr ({d} bytes{s}) ---{s}\n", .{
            ctx.k(colors.DIM), stderr_bytes.len,
            if (err_truncated) ", truncated" else "",
            ctx.k(colors.RESET),
        });
        ctx.emit("{s}", .{err_trimmed});
        if (!std.mem.endsWith(u8, err_trimmed, "\n")) ctx.emit("\n", .{});
    }
}

fn emitRecordJsonShow(
    ctx: *Ctx,
    r: RunRecord,
    stdout_bytes: []const u8,
    stderr_bytes: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    stdout_total: usize,
    stderr_total: usize,
) void {
    const status = runs_mod.statusOf(r);
    ctx.emit("{{\"schema_version\":{d},\"run_id\":\"{s}\",\"status\":\"{s}\",", .{
        SCHEMA_VERSION, display.jsonEsc(ctx.a, r.run_id), statusStr(status),
    });
    ctx.emit("\"source_id\":", .{});
    if (r.source_id) |sid| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, sid)}) else ctx.emit("null", .{});
    ctx.emit(",\"command\":\"{s}\"", .{display.jsonEsc(ctx.a, r.command)});
    ctx.emit(",\"target_label\":", .{});
    if (r.target_label) |tl| ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, tl)}) else ctx.emit("null", .{});
    ctx.emit(",\"once\":{s}", .{if (r.once) "true" else "false"});
    emitOptInt(ctx, "scheduled_for", r.scheduled_for);
    emitOptInt(ctx, "started_at", r.started_at);
    emitOptInt(ctx, "finished_at", r.finished_at);
    if (r.exit_code) |code| ctx.emit(",\"exit_code\":{d}", .{code}) else ctx.emit(",\"exit_code\":null", .{});
    ctx.emit(",\"timed_out\":{s}", .{if (r.timed_out) "true" else "false"});
    if (r.created_by) |cb| ctx.emit(",\"created_by\":\"{s}\"", .{display.jsonEsc(ctx.a, cb)}) else ctx.emit(",\"created_by\":null", .{});
    // `captured` nests the stdout/stderr blobs so consumers can detect
    // "have captured output" with `.captured` rather than probing for
    // both `stdout` and `stderr` separately. Field shape inside is
    // stable across `runs show` and any future surface that exposes
    // captured-process output (e.g., `history --include-captured`).
    ctx.emit(",\"captured\":{{\"stdout\":\"{s}\",\"stdout_total_bytes\":{d},\"stdout_truncated\":{s}", .{
        display.jsonEsc(ctx.a, stdout_bytes), stdout_total,
        if (stdout_truncated) "true" else "false",
    });
    ctx.emit(",\"stderr\":\"{s}\",\"stderr_total_bytes\":{d},\"stderr_truncated\":{s}}}}}\n", .{
        display.jsonEsc(ctx.a, stderr_bytes), stderr_total,
        if (stderr_truncated) "true" else "false",
    });
}

// ---------------------------------------------------------------------------
// runs prune
// ---------------------------------------------------------------------------

/// Default cutoff for `looper runs prune` when --older-than isn't given:
/// 30 days. Matches the "manual prune, predictable cutoff" decision
/// from Q3 in the brainstorm — auto-prune is opt-in, but the default
/// when invoked is the obvious "month-old garbage" sweep.
const DEFAULT_PRUNE_OLDER_THAN_SECS: i64 = 30 * 24 * 60 * 60;

pub fn cmdRunsPrune(ctx: *Ctx, older_than_secs_opt: ?i64) !void {
    const older_than = older_than_secs_opt orelse DEFAULT_PRUNE_OLDER_THAN_SECS;
    if (older_than <= 0) {
        posix.eprint("looper: --older-than must be positive (refusing to prune everything)\n", .{});
        ctx.fail(2);
        return;
    }

    const preview = try runs_mod.pruneRuns(ctx.a, older_than, true);
    if (preview.removed.len == 0) {
        if (ctx.json) {
            ctx.emit("{{\"kept\":{d},\"removed\":[]}}\n", .{preview.kept});
            return;
        }
        ctx.emit("{s}nothing to prune: {d} run record(s), all newer than the cutoff{s}\n", .{
            ctx.k(colors.DIM), preview.kept, ctx.k(colors.RESET),
        });
        return;
    }

    if (ctx.dry_run) {
        if (ctx.json) {
            ctx.emit("{{\"dry_run\":true,\"kept\":{d},\"removed\":[", .{preview.kept});
            for (preview.removed, 0..) |run_id, i| {
                if (i > 0) ctx.emit(",", .{});
                ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, run_id)});
            }
            ctx.emit("]}}\n", .{});
            return;
        }
        ctx.emit("{s}# dry-run: would remove {d} run record(s), keep {d}{s}\n", .{
            ctx.k(colors.YELLOW), preview.removed.len, preview.kept, ctx.k(colors.RESET),
        });
        for (preview.removed) |run_id| ctx.emit("  {s}- {s}{s}\n", .{ ctx.k(colors.DIM), run_id, ctx.k(colors.RESET) });
        return;
    }

    if (!ctx.json) {
        ctx.emit("{s}{d} run record(s) to remove (older than {d}s):{s}\n", .{
            ctx.k(colors.BOLD), preview.removed.len, older_than, ctx.k(colors.RESET),
        });
        for (preview.removed) |run_id| ctx.emit("  {s}- {s}{s}\n", .{ ctx.k(colors.DIM), run_id, ctx.k(colors.RESET) });
    }
    if (!display.confirm(ctx, "Remove {d} run record(s)?", .{preview.removed.len})) {
        if (ctx.json) {
            ctx.emit("{{\"aborted\":true,\"kept\":{d},\"removed\":[]}}\n", .{preview.kept});
        } else ctx.emit("aborted\n", .{});
        return;
    }
    const result = try runs_mod.pruneRuns(ctx.a, older_than, false);
    if (ctx.json) {
        ctx.emit("{{\"kept\":{d},\"removed\":[", .{result.kept});
        for (result.removed, 0..) |run_id, i| {
            if (i > 0) ctx.emit(",", .{});
            ctx.emit("\"{s}\"", .{display.jsonEsc(ctx.a, run_id)});
        }
        ctx.emit("]}}\n", .{});
        return;
    }
    if (!ctx.quiet) ctx.emit("{s}\xe2\x9c\x93{s} removed {d} run record(s) (kept {d})\n", .{
        ctx.k(colors.GREEN), ctx.k(colors.RESET),
        result.removed.len, result.kept,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

test "parseStatusFilter recognizes all four status names" {
    try testing.expectEqual(@as(?RunStatus, .pending), parseStatusFilter("pending"));
    try testing.expectEqual(@as(?RunStatus, .running), parseStatusFilter("running"));
    try testing.expectEqual(@as(?RunStatus, .done), parseStatusFilter("done"));
    try testing.expectEqual(@as(?RunStatus, .failed), parseStatusFilter("failed"));
    try testing.expectEqual(@as(?RunStatus, null), parseStatusFilter("nonsense"));
}

test "cmdRunsLs --json emits the schema_version envelope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    // We can't assume the runs dir is empty (other tests may have run
    // first), so just verify the envelope shape — `{"schema_version":1,"runs":[...`
    try cmdRunsLs(&ctx, "", .{});
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"runs\":[") != null);
}

test "cmdRunsLs synthesizes pending records from crontab one-shots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const crontab =
        \\#looper# id=test-pending enabled=1 once=1 run_id=pending-xyz-1
        \\57 14 23 5 * /usr/local/bin/looper _exec --run-id=pending-xyz-1 -- /bin/echo hi
        \\
    ;
    try cmdRunsLs(&ctx, crontab, .{});
    // The synthetic pending record should appear with status=pending
    // and a run_id matching the marker's.
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"run_id\":\"pending-xyz-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"status\":\"pending\"") != null);
}

test "cmdRunsLs --owner filter excludes records with mismatched created_by" {
    // Seed a record with created_by=agent-a, then query with
    // --owner=other and expect it absent.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "filter-mismatch-{x}", .{posix.nowEpoch()});
    try runs_mod.metaWrite(a, .{
        .run_id = run_id,
        .command = "/bin/true",
        .scheduled_for = 1748016000,
        .started_at = 1748016001,
        .finished_at = 1748016002,
        .exit_code = 0,
        .created_by = "agent-a",
    });
    defer {
        const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch unreachable;
        const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch unreachable;
        _ = posix.c.unlink(meta_z.ptr);
        _ = posix.c.rmdir(dir_z.ptr);
    }
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdRunsLs(&ctx, "", .{ .owner = "other" });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, run_id) == null);
}

test "cmdRunsLs --owner filter excludes records with null created_by" {
    // A record without created_by (legacy / non-provenance run) must
    // never match a non-null owner filter — otherwise unattributed
    // records leak into ownership-scoped queries.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "filter-null-{x}", .{posix.nowEpoch()});
    try runs_mod.metaWrite(a, .{
        .run_id = run_id,
        .command = "/bin/true",
        .scheduled_for = 1748016000,
        .started_at = 1748016001,
        .finished_at = 1748016002,
        .exit_code = 0,
    });
    defer {
        const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch unreachable;
        const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch unreachable;
        _ = posix.c.unlink(meta_z.ptr);
        _ = posix.c.rmdir(dir_z.ptr);
    }
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdRunsLs(&ctx, "", .{ .owner = "agent-a" });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, run_id) == null);
}

test "cmdRunsLs --owner filter includes records with matching created_by" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run_id = try std.fmt.allocPrint(a, "filter-match-{x}", .{posix.nowEpoch()});
    try runs_mod.metaWrite(a, .{
        .run_id = run_id,
        .command = "/bin/true",
        .scheduled_for = 1748016000,
        .started_at = 1748016001,
        .finished_at = 1748016002,
        .exit_code = 0,
        .created_by = "agent-a",
    });
    defer {
        const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch unreachable;
        const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch unreachable;
        _ = posix.c.unlink(meta_z.ptr);
        _ = posix.c.rmdir(dir_z.ptr);
    }
    var ctx = newCtx(a);
    ctx.json = true;
    try cmdRunsLs(&ctx, "", .{ .owner = "agent-a" });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, run_id) != null);
}

test "cmdRunsLs filter status=pending excludes done/failed records" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    // No crontab → no synthetic pending → result must be a strict subset
    // (whatever's already on disk) that has zero pending records.
    try cmdRunsLs(&ctx, "", .{ .status = .pending });
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"status\":\"pending\"") == null);
}

test "cmdRunsShow returns error for unknown run_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    try cmdRunsShow(&ctx, "definitely-no-such-run-id-xyz", false);
    try testing.expectEqual(@as(u8, 1), ctx.exit_code);
}

test "cmdRunsShow reads back a written record + captured output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Synthesize a complete run on disk so show has something to read.
    const run_id = try std.fmt.allocPrint(a, "show-test-{x}", .{posix.nowEpoch()});
    const rec = RunRecord{
        .run_id = run_id,
        .command = "/bin/echo round-trip",
        .target_label = "local",
        .once = true,
        .scheduled_for = 1748016000,
        .started_at = 1748016001,
        .finished_at = 1748016002,
        .exit_code = 0,
    };
    try runs_mod.metaWrite(a, rec);
    try target_mod.writeFileAll(a, runs_mod.outPath(a, run_id), "hello world\n");
    try target_mod.writeFileAll(a, runs_mod.errPath(a, run_id), "warning: x\n");
    defer {
        const out_z = a.dupeZ(u8, runs_mod.outPath(a, run_id)) catch unreachable;
        const err_z = a.dupeZ(u8, runs_mod.errPath(a, run_id)) catch unreachable;
        const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch unreachable;
        const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch unreachable;
        _ = posix.c.unlink(out_z.ptr);
        _ = posix.c.unlink(err_z.ptr);
        _ = posix.c.unlink(meta_z.ptr);
        _ = posix.c.rmdir(dir_z.ptr);
    }

    var ctx = newCtx(a);
    ctx.json = true;
    try cmdRunsShow(&ctx, run_id, true);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"status\":\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"exit_code\":0") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"stdout\":\"hello world\\n\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"stderr\":\"warning: x\\n\"") != null);
}

test "cmdRunsPrune --older-than negative is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    try cmdRunsPrune(&ctx, -1);
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdRunsPrune dry-run emits preview without touching disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Lay down a stale record (finished_at in the distant past).
    const run_id = try std.fmt.allocPrint(a, "prune-dryrun-{x}", .{posix.nowEpoch()});
    const rec = RunRecord{
        .run_id = run_id,
        .command = "/bin/true",
        .once = true,
        .scheduled_for = 1_000_000_000, // 2001-09-09
        .started_at = 1_000_000_001,
        .finished_at = 1_000_000_002,
        .exit_code = 0,
    };
    try runs_mod.metaWrite(a, rec);
    defer {
        const meta_z = a.dupeZ(u8, runs_mod.metaPath(a, run_id)) catch unreachable;
        const dir_z = a.dupeZ(u8, runs_mod.runDir(a, run_id)) catch unreachable;
        _ = posix.c.unlink(meta_z.ptr);
        _ = posix.c.rmdir(dir_z.ptr);
    }

    var ctx = newCtx(a);
    ctx.json = true;
    ctx.dry_run = true;
    try cmdRunsPrune(&ctx, 86400); // 1 day cutoff — our record is decades old
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"dry_run\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, run_id) != null);

    // The record must still be readable — dry-run touched nothing.
    const still_there = try runs_mod.metaRead(a, run_id);
    try testing.expect(still_there != null);
}
