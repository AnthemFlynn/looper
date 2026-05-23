//! Backup-related verbs: `backup` (snapshot), `backups` (list + prune),
//! `restore`, and `import` (which is the only path that adopts a foreign
//! line into management — sitting here because, like restore, it's a
//! one-shot "rewrite the file" mutation).

const std = @import("std");
const posix = @import("../posix.zig");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const backup_mod = @import("../crontab/backup.zig");
const model = @import("../crontab/model.zig");
const sched_mod = @import("../cron/schedule.zig");
const humanize = @import("../cron/humanize.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");
const core = @import("core.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

pub fn cmdBackup(ctx: *Ctx, t: Target, content: []const u8) !void {
    const p = backup_mod.doBackup(ctx.a, t, content) orelse {
        posix.eprint("looper: backup failed\n", .{});
        ctx.fail(1);
        return;
    };
    ctx.emit("{s}\xe2\x9c\x93{s} backed up {s} to {s}\n", .{ ctx.k(colors.GREEN), ctx.k(colors.RESET), t.label(ctx.a), p });
}

pub fn cmdRestore(ctx: *Ctx, t: Target, current: []const u8, given_path: ?[]const u8, from_stamp: ?[]const u8) !void {
    // `--from <stamp>` resolves against the target's backup dir; the
    // bare positional path remains for explicit file restores
    // (cross-target imports, manually edited snapshots). Honouring both
    // at once would silently prefer one — refuse instead.
    if (given_path != null and from_stamp != null) {
        posix.eprint("looper: restore takes EITHER a positional path OR --from <stamp>, not both\n", .{});
        ctx.fail(2);
        return;
    }
    const path: []const u8 = if (from_stamp) |stamp| blk: {
        const entry = backup_mod.findByStamp(ctx.a, t, stamp) catch |e| switch (e) {
            backup_mod.StampError.Ambiguous => {
                posix.eprint("looper: stamp '{s}' matches more than one backup on {s} — narrow it (try `looper backups`)\n", .{ stamp, t.label(ctx.a) });
                ctx.fail(2);
                return;
            },
            backup_mod.StampError.NotFound => {
                posix.eprint("looper: no backup matching '{s}' on {s} (try `looper backups`)\n", .{ stamp, t.label(ctx.a) });
                ctx.fail(1);
                return;
            },
            else => return e,
        };
        break :blk entry.path;
    } else given_path orelse backup_mod.newestBackup(ctx.a, t) orelse {
        posix.eprint("looper: no backups for {s}\n", .{t.label(ctx.a)});
        ctx.fail(1);
        return;
    };
    const data = target_mod.readFileAll(ctx.a, path) catch {
        posix.eprint("looper: cannot read backup {s}\n", .{path});
        ctx.fail(1);
        return;
    };
    ctx.emit("{s}restoring {s} from {s}{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), path, ctx.k(colors.RESET) });
    try core.applyMutation(ctx, t, current, data, "restored snapshot");
}

// ─── backups (list) and backups prune ────────────────────────────────────────
// Read-only listing and a guarded pruner. Neither touches the crontab
// — they operate only inside the per-target backup directory under
// $XDG_STATE_HOME/looper/backups/<slug>/. Prune is the only destructive
// path in this module and must go through `confirm` (or `--yes` / a
// non-tty `--dry-run`).

/// Format an arbitrary byte count as a short human string. KiB-based,
/// the convention `ls -h` follows; we deliberately don't dignify
/// kilobyte ambiguity by labelling them "KiB" — the listing is for
/// humans, not for parsers (the JSON output carries `size_bytes`).
fn humanSize(a: std.mem.Allocator, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(a, "{d} B", .{bytes}) catch "";
    const kb: u64 = bytes / 1024;
    if (kb < 1024) return std.fmt.allocPrint(a, "{d}.{d} KB", .{ kb, (bytes * 10 / 1024) % 10 }) catch "";
    const mb_x10: u64 = bytes * 10 / (1024 * 1024);
    return std.fmt.allocPrint(a, "{d}.{d} MB", .{ mb_x10 / 10, mb_x10 % 10 }) catch "";
}

/// "12m ago", "1d 2h ago", "now" — derived from `relTime` (which gives
/// "12m" for past deltas and "in 12m" for future). For backups we always
/// want the past-tense form, so we hand it a negative delta and suffix
/// " ago" only when relTime returned more than the literal "now".
fn humanAge(a: std.mem.Allocator, mtime: i64, now: i64) []const u8 {
    const rt = humanize.relTime(a, mtime - now);
    if (std.mem.eql(u8, rt, "now")) return rt;
    return std.fmt.allocPrint(a, "{s} ago", .{std.mem.trimStart(u8, rt, " ")}) catch rt;
}

pub fn cmdBackups(ctx: *Ctx, t: Target) !void {
    const list = try backup_mod.listBackups(ctx.a, t);
    if (ctx.json) {
        const target_label = t.label(ctx.a);
        ctx.emit("{{\"target\":\"{s}\",\"backups\":[", .{display.jsonEsc(ctx.a, target_label)});
        for (list, 0..) |e, i| {
            if (i > 0) ctx.emit(",", .{});
            ctx.emit("{{\"stamp\":\"{s}\",\"mtime\":{d},\"size_bytes\":{d},\"path\":\"{s}\"}}", .{
                e.stamp,             e.mtime, e.size_bytes,
                display.jsonEsc(ctx.a, e.path),
            });
        }
        ctx.emit("]}}\n", .{});
        return;
    }
    if (list.len == 0) {
        ctx.emit("{s}no backups for {s} yet{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), ctx.k(colors.RESET) });
        return;
    }
    ctx.emit("{s}{s}  ({d} snapshot(s)){s}\n", .{ ctx.k(colors.BOLD), t.label(ctx.a), list.len, ctx.k(colors.RESET) });
    const now = posix.nowEpoch();
    for (list) |e| {
        const size = humanSize(ctx.a, e.size_bytes);
        const age = humanAge(ctx.a, e.mtime, now);
        ctx.emit("  {s}{s}{s}  {s}  {s}{s}{s}\n", .{
            ctx.k(colors.CYAN),  e.stamp, ctx.k(colors.RESET),
            display.padTo(ctx.a, size, 10),
            ctx.k(colors.DIM),   age,     ctx.k(colors.RESET),
        });
    }
    ctx.emit("{s}restore the newest with 'looper restore'; a specific one with 'looper restore --from <stamp>'{s}\n", .{ ctx.k(colors.DIM), ctx.k(colors.RESET) });
}

pub fn cmdBackupsPrune(ctx: *Ctx, t: Target, keep: usize) !void {
    // Floor at 1: zero is the "remove all" footgun the project doc
    // explicitly outlaws (CLAUDE.md). Surface the error here so the
    // user can re-issue with a sane value; don't auto-promote to 1.
    if (keep == 0) {
        posix.eprint("looper: --keep must be >= 1 (refusing to delete every backup)\n", .{});
        ctx.fail(2);
        return;
    }
    const preview = try backup_mod.pruneBackups(ctx.a, t, keep, true);
    if (preview.removed.len == 0) {
        if (ctx.json) {
            ctx.emit("{{\"target\":\"{s}\",\"kept\":{d},\"removed\":[]}}\n", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)), preview.kept.len,
            });
            return;
        }
        ctx.emit("{s}nothing to prune on {s}: {d} backup(s), keep {d}{s}\n", .{
            ctx.k(colors.DIM), t.label(ctx.a), preview.kept.len, keep, ctx.k(colors.RESET),
        });
        return;
    }
    if (ctx.dry_run) {
        if (ctx.json) {
            ctx.emit("{{\"dry_run\":true,\"target\":\"{s}\",\"kept\":{d},\"removed\":[", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)), preview.kept.len,
            });
            for (preview.removed, 0..) |e, i| {
                if (i > 0) ctx.emit(",", .{});
                ctx.emit("{{\"stamp\":\"{s}\",\"path\":\"{s}\"}}", .{ e.stamp, display.jsonEsc(ctx.a, e.path) });
            }
            ctx.emit("]}}\n", .{});
            return;
        }
        ctx.emit("{s}# dry-run: would remove {d} backup(s) on {s}, keep newest {d}{s}\n", .{
            ctx.k(colors.YELLOW), preview.removed.len, t.label(ctx.a), keep, ctx.k(colors.RESET),
        });
        for (preview.removed) |e| ctx.emit("  {s}- {s}{s}\n", .{ ctx.k(colors.DIM), e.stamp, ctx.k(colors.RESET) });
        return;
    }
    if (!ctx.json) {
        ctx.emit("{s}{d} backup(s) to remove on {s}, keep newest {d}:{s}\n", .{
            ctx.k(colors.BOLD), preview.removed.len, t.label(ctx.a), keep, ctx.k(colors.RESET),
        });
        for (preview.removed) |e| ctx.emit("  {s}- {s}{s}\n", .{ ctx.k(colors.DIM), e.stamp, ctx.k(colors.RESET) });
    }
    if (!display.confirm(ctx, "Remove {d} backup(s)?", .{preview.removed.len})) {
        if (ctx.json) {
            ctx.emit("{{\"target\":\"{s}\",\"aborted\":true,\"kept\":{d},\"removed\":[]}}\n", .{
                display.jsonEsc(ctx.a, t.label(ctx.a)), preview.kept.len,
            });
        } else ctx.emit("aborted\n", .{});
        return;
    }
    const result = try backup_mod.pruneBackups(ctx.a, t, keep, false);
    if (ctx.json) {
        ctx.emit("{{\"target\":\"{s}\",\"kept\":{d},\"removed\":[", .{
            display.jsonEsc(ctx.a, t.label(ctx.a)), result.kept.len,
        });
        for (result.removed, 0..) |e, i| {
            if (i > 0) ctx.emit(",", .{});
            ctx.emit("{{\"stamp\":\"{s}\",\"path\":\"{s}\"}}", .{ e.stamp, display.jsonEsc(ctx.a, e.path) });
        }
        ctx.emit("]}}\n", .{});
        return;
    }
    if (!ctx.quiet) ctx.emit("{s}\xe2\x9c\x93{s} removed {d} backup(s) on {s} (kept newest {d})\n", .{
        ctx.k(colors.GREEN), ctx.k(colors.RESET),
        result.removed.len, t.label(ctx.a), result.kept.len,
    });
}

pub fn cmdImport(ctx: *Ctx, t: Target, content: []const u8) !void {
    var ct = try model.parseCrontab(ctx.a, content);
    var n: usize = 0;
    var skipped: usize = 0;
    for (ct.items.items) |*it| switch (it.*) {
        .job => |*j| if (j.foreign) {
            // Validate the schedule before adopting; lines that aren't real
            // cron stay foreign and visible in `ls` rather than being
            // promoted to a managed job that won't ever fire.
            _ = sched_mod.parseSchedule(j.schedule) catch {
                posix.eprint("looper: skipping unmanaged line with unparseable schedule: {s} {s}\n", .{ j.schedule, j.command });
                skipped += 1;
                continue;
            };
            j.foreign = false;
            j.enabled = true;
            j.id = display.slugUnique(ctx.a, &ct, j.command);
            n += 1;
        },
        else => {},
    };
    if (skipped > 0) ctx.emit("{s}skipped {d} unmanaged line(s) that don't parse as cron{s}\n", .{ ctx.k(colors.DIM), skipped, ctx.k(colors.RESET) });
    if (n == 0) {
        ctx.emit("{s}no unmanaged jobs to import on {s}{s}\n", .{ ctx.k(colors.DIM), t.label(ctx.a), ctx.k(colors.RESET) });
        return;
    }
    const new_content = try model.serialize(ctx.a, &ct);
    const verb = try std.fmt.allocPrint(ctx.a, "imported {d} job(s)", .{n});
    try core.applyMutation(ctx, t, content, new_content, verb);
}

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .a = a, .color = false, .yes = true };
}

/// Lay down a controlled set of backup stamps under the target's slug.
/// Returns the target with a unique path; cleanup is via a defer in
/// the test that calls this (each test arena is its own world).
fn seedBackups(a: std.mem.Allocator, stamps: []const []const u8) !Target {
    const t: Target = .{
        .kind = .file,
        .path = try std.fmt.allocPrint(a, "/tmp/looper-cmd-bkup-{x}.crontab", .{posix.nowEpoch()}),
    };
    const dir = backup_mod.backupDir(a, t);
    backup_mod.mkdirP(a, dir);
    for (stamps, 0..) |stamp, idx| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}.crontab", .{ dir, stamp });
        const body = try std.fmt.allocPrint(a, "# seed {d}\n0 {d} * * * /bin/echo {s}\n", .{ idx, idx, stamp });
        try target_mod.writeFileAll(a, path, body);
    }
    return t;
}

fn cleanupBackupDir(a: std.mem.Allocator, t: Target) void {
    const dir = backup_mod.backupDir(a, t);
    const dz = a.dupeZ(u8, dir) catch return;
    const d = posix.c.opendir(dz.ptr) orelse return;
    defer _ = posix.c.closedir(d);
    while (true) {
        std.c._errno().* = 0;
        const ent = posix.c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".crontab")) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
        const pz = a.dupeZ(u8, full) catch continue;
        _ = posix.c.unlink(pz.ptr);
    }
}

test "cmdBackups on an empty dir reports no backups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const t: Target = .{ .kind = .file, .path = try std.fmt.allocPrint(a, "/tmp/looper-no-bkup-{x}.crontab", .{posix.nowEpoch()}) };
    try cmdBackups(&ctx, t);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "no backups for") != null);
}

test "cmdBackups lists newest-first with size + age" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{ "20260520T180000Z", "20260522T093015Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackups(&ctx, t);
    // Newest stamp must appear first in the table.
    const idx_newest = std.mem.indexOf(u8, ctx.buf.items, "20260522T093015Z") orelse return error.MissingNewest;
    const idx_older = std.mem.indexOf(u8, ctx.buf.items, "20260520T180000Z") orelse return error.MissingOlder;
    try testing.expect(idx_newest < idx_older);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "(2 snapshot(s))") != null);
}

test "cmdBackups --json emits structured array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.json = true;
    const stamps = [_][]const u8{"20260522T093015Z"};
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackups(&ctx, t);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"target\":\"file:") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"stamp\":\"20260522T093015Z\"") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "\"size_bytes\":") != null);
}

test "cmdBackupsPrune --keep 0 is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const t: Target = .{ .kind = .file, .path = "/tmp/looper-irrelevant.crontab" };
    try cmdBackupsPrune(&ctx, t, 0);
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdBackupsPrune removes excess + keeps newest N" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{
        "20260101T000000Z",
        "20260102T000000Z",
        "20260103T000000Z",
        "20260104T000000Z",
    };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackupsPrune(&ctx, t, 2);
    const after = try backup_mod.listBackups(a, t);
    try testing.expectEqual(@as(usize, 2), after.len);
    try testing.expectEqualStrings("20260104T000000Z", after[0].stamp);
    try testing.expectEqualStrings("20260103T000000Z", after[1].stamp);
}

test "cmdBackupsPrune --dry-run lists removals but doesn't unlink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    ctx.dry_run = true;
    const stamps = [_][]const u8{ "20260101T000000Z", "20260102T000000Z", "20260103T000000Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackupsPrune(&ctx, t, 1);
    // Files all still present.
    const after = try backup_mod.listBackups(a, t);
    try testing.expectEqual(@as(usize, 3), after.len);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "would remove 2 backup(s)") != null);
}

test "cmdBackupsPrune noop when count <= keep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{ "20260101T000000Z", "20260102T000000Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdBackupsPrune(&ctx, t, 5);
    try testing.expect(std.mem.indexOf(u8, ctx.buf.items, "nothing to prune") != null);
    const after = try backup_mod.listBackups(a, t);
    try testing.expectEqual(@as(usize, 2), after.len);
}

test "cmdRestore --from resolves a unique stamp substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{"20260522T093015Z"};
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    defer _ = posix.c.unlink((a.dupeZ(u8, t.path) catch unreachable).ptr);
    try cmdRestore(&ctx, t, "", null, "20260522");
    // The seeded backup body contains "echo 20260522T093015Z" — that's
    // what should land in the target file after restore.
    const got = try target_mod.readFileAll(a, t.path);
    try testing.expect(std.mem.indexOf(u8, got, "echo 20260522T093015Z") != null);
}

test "cmdRestore --from with ambiguous stamp errors out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const stamps = [_][]const u8{ "20260522T093015Z", "20260522T180000Z" };
    const t = try seedBackups(a, &stamps);
    defer cleanupBackupDir(a, t);
    try cmdRestore(&ctx, t, "", null, "20260522");
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}

test "cmdRestore rejects both positional and --from at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = newCtx(a);
    const t: Target = .{ .kind = .file, .path = "/tmp/looper-irrelevant.crontab" };
    try cmdRestore(&ctx, t, "", "/some/path", "20260522");
    try testing.expectEqual(@as(u8, 2), ctx.exit_code);
}
