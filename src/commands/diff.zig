//! `diff` — drift detection. Answers the agent's recurring question
//! "has the world changed since I last looked?" by reporting cron
//! activity the crontab will run that looper does not manage: "foreign"
//! lines added out-of-band — by a human via `crontab -e`, by another
//! agent, or by config management. Exits nonzero when any drift is
//! found, zero when looper's managed set fully accounts for the
//! crontab. This is the read side of state reconciliation; remediation
//! is deliberately out of scope (`diff` reports, `apply` fixes).
//!
//! Scope (v0.3 #10, half 2): foreign-line detection. Detecting that a
//! *managed* job was edited or removed externally (#10's `~` / `-`
//! categories) needs a stored per-job expectation looper doesn't
//! persist today, and `--scope mine` builds on that — both deferred.
//! Foreign-line presence is the drift signal detectable from the
//! crontab alone, and the one an unmanaged-job sweep actually needs.

const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const target_mod = @import("../crontab/target.zig");
const model = @import("../crontab/model.zig");
const display = @import("../ui/display.zig");
const colors = @import("../ui/colors.zig");

const Ctx = ctx_mod.Ctx;
const Target = target_mod.Target;

/// JSON envelope version. Matches the rest of the read verbs (`ls`,
/// `agenda`, `runs ls`): adding fields stays at v1, reshaping bumps it.
pub const SCHEMA_VERSION: u32 = 1;

const Summary = struct {
    managed: usize,
    /// Foreign jobs in crontab order. Borrowed from the parsed Crontab;
    /// valid for that allocation's lifetime (the arena, in practice).
    foreign: []const model.Job,

    fn drift(self: Summary) bool {
        return self.foreign.len > 0;
    }
};

/// Partition a parsed crontab into managed-job count + the foreign jobs.
/// Pure over the parsed model so the categorization is unit-testable
/// without touching a real crontab or stdout.
fn summarize(a: std.mem.Allocator, ct: *const model.Crontab) !Summary {
    var managed: usize = 0;
    var foreign: std.ArrayList(model.Job) = .empty;
    for (ct.items.items) |it| switch (it) {
        .job => |j| {
            if (j.foreign) try foreign.append(a, j) else managed += 1;
        },
        else => {},
    };
    return .{ .managed = managed, .foreign = foreign.items };
}

pub fn cmdDiff(ctx: *Ctx, t: Target, content: []const u8) !void {
    const ct = try model.parseCrontab(ctx.a, content);
    const sum = try summarize(ctx.a, &ct);
    const target_label = t.label(ctx.a);
    const drift = sum.drift();

    if (ctx.json) {
        ctx.emit(
            "{{\"schema_version\":{d},\"target\":\"{s}\",\"clean\":{s},\"managed_count\":{d},\"foreign\":[",
            .{ SCHEMA_VERSION, display.jsonEsc(ctx.a, target_label), if (drift) "false" else "true", sum.managed },
        );
        for (sum.foreign, 0..) |j, i| {
            if (i > 0) ctx.emit(",", .{});
            ctx.emit(
                "{{\"schedule\":\"{s}\",\"command\":\"{s}\"}}",
                .{ display.jsonEsc(ctx.a, j.schedule), display.jsonEsc(ctx.a, j.command) },
            );
        }
        ctx.emit("]}}\n", .{});
        // Drift sets a nonzero exit even under --json — the exit code is
        // the cheap signal a script polls before bothering to parse.
        if (drift) ctx.fail(1);
        return;
    }

    if (!drift) {
        ctx.emit("{s}no drift on {s}{s}  {s}({d} managed, 0 foreign){s}\n", .{
            ctx.k(colors.GREEN),     target_label, ctx.k(colors.RESET),
            ctx.k(colors.DIM),       sum.managed,  ctx.k(colors.RESET),
        });
        return;
    }

    ctx.emit("{s}{s}drift on {s}{s}  {d} foreign line{s} cron will run that looper does not manage:\n", .{
        ctx.k(colors.BOLD), ctx.k(colors.YELLOW), target_label, ctx.k(colors.RESET),
        sum.foreign.len,    if (sum.foreign.len == 1) "" else "s",
    });
    for (sum.foreign) |j| {
        ctx.emit("  {s}+{s} {s}  {s}\n", .{
            ctx.k(colors.YELLOW), ctx.k(colors.RESET),
            display.padTo(ctx.a, j.schedule, 18),
            j.command,
        });
    }
    // Foreign lines present → exit nonzero so `diff && ...` gates on a
    // clean managed set. Routed through ctx.fail (first-failure-wins) so
    // a multi-target run reports drift on any target.
    ctx.fail(1);
}

const testing = std.testing;

test "summarize: empty crontab is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ct = try model.parseCrontab(a, "");
    const sum = try summarize(a, &ct);
    try testing.expectEqual(@as(usize, 0), sum.managed);
    try testing.expectEqual(@as(usize, 0), sum.foreign.len);
    try testing.expect(!sum.drift());
}

test "summarize: plain cron lines are foreign drift" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\# a comment, not a job
        \\SHELL=/bin/sh
        \\0 23 * * * /opt/some-foreign-job
        \\*/15 * * * * /usr/bin/other
        \\
    ;
    var ct = try model.parseCrontab(a, content);
    const sum = try summarize(a, &ct);
    try testing.expectEqual(@as(usize, 0), sum.managed);
    try testing.expectEqual(@as(usize, 2), sum.foreign.len);
    try testing.expect(sum.drift());
    // Foreign jobs preserve their schedule + command for reporting.
    try testing.expectEqualStrings("0 23 * * *", sum.foreign[0].schedule);
    try testing.expectEqualStrings("/opt/some-foreign-job", sum.foreign[0].command);
}

test "summarize: managed jobs do not count as drift" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Round-trip a managed job through serialize so the marker syntax is
    // whatever the model actually emits, not a hand-built guess.
    var built: model.Crontab = .{};
    try built.items.append(a, .{ .job = .{
        .id = "rotate",
        .enabled = true,
        .schedule = "@daily",
        .command = "/usr/local/bin/rotate",
    } });
    const serialized = try model.serialize(a, &built);

    var ct = try model.parseCrontab(a, serialized);
    const sum = try summarize(a, &ct);
    try testing.expectEqual(@as(usize, 1), sum.managed);
    try testing.expectEqual(@as(usize, 0), sum.foreign.len);
    try testing.expect(!sum.drift());
}

test "summarize: mixed managed + foreign reports only foreign as drift" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var built: model.Crontab = .{};
    try built.items.append(a, .{ .job = .{
        .id = "managed-one",
        .enabled = true,
        .schedule = "@hourly",
        .command = "/bin/true",
    } });
    const managed_text = try model.serialize(a, &built);
    const content = try std.fmt.allocPrint(a, "{s}0 23 * * * /opt/foreign\n", .{managed_text});

    var ct = try model.parseCrontab(a, content);
    const sum = try summarize(a, &ct);
    try testing.expectEqual(@as(usize, 1), sum.managed);
    try testing.expectEqual(@as(usize, 1), sum.foreign.len);
    try testing.expect(sum.drift());
}
