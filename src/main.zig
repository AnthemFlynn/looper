//! Entry point: orchestrates argv parsing (in `cli`), command dispatch,
//! target list construction, and the per-target loop. The hard logic
//! lives in `cli.zig` (parsing) and `commands.zig` (subcommands).
const std = @import("std");
const posix = @import("posix.zig");
const c = posix.c;
const ctx_mod = @import("ctx.zig");
const cli = @import("cli.zig");
const cmds = @import("commands.zig");
const help_mod = @import("ui/help.zig");
const colors = @import("ui/colors.zig");
const target_mod = @import("crontab/target.zig");
const tz_mod = @import("tz.zig");

const Cmd = enum { ls, add, edit, rm, enable, disable, show, run, explain, import, backup, restore, doctor, version, help, unknown };

fn parseCmd(s: []const u8) Cmd {
    // Note: `set` aliases `edit` (the partial-update command), not `add`.
    // Previously `set` was an undocumented alias for `add`; redirecting
    // it to `edit` makes the natural reading "set the schedule of X to
    // Y" do the smarter thing — no positional re-statement of the other
    // field, so the command users don't want to change can't drift.
    const map = .{
        .{ "ls", Cmd.ls },           .{ "list", Cmd.ls },         .{ "add", Cmd.add },         .{ "edit", Cmd.edit },
        .{ "set", Cmd.edit },        .{ "rm", Cmd.rm },           .{ "remove", Cmd.rm },       .{ "delete", Cmd.rm },
        .{ "enable", Cmd.enable },   .{ "disable", Cmd.disable }, .{ "show", Cmd.show },       .{ "run", Cmd.run },
        .{ "explain", Cmd.explain }, .{ "import", Cmd.import },   .{ "backup", Cmd.backup },   .{ "restore", Cmd.restore },
        .{ "doctor", Cmd.doctor },   .{ "version", Cmd.version }, .{ "help", Cmd.help },
    };
    inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return .unknown;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctx_mod.Ctx{ .a = a };
    ctx.color = c.isatty(1) != 0 and posix.getenv("NO_COLOR") == null;

    const argv = try init.args.toSlice(a);
    const parsed = try cli.parseArgv(a, argv, &ctx);
    if (parsed.bad_option) |bad| {
        posix.eprint("looper: unknown option '{s}' (try: looper help)\n", .{bad});
        ctx.fail(2);
        ctx.flush();
        std.process.exit(ctx.exit_code);
    }

    if (parsed.force_help or parsed.positionals.len == 0) {
        help_mod.printHelp(&ctx);
        ctx.flush();
        return;
    }
    const cmd = parseCmd(parsed.positionals[0]);
    const rest = parsed.positionals[1..];
    if (cmd == .help) {
        help_mod.printHelp(&ctx);
        ctx.flush();
        return;
    }
    if (cmd == .version) {
        ctx.emit("looper {s}\n", .{help_mod.VERSION});
        ctx.flush();
        return;
    }
    if (cmd == .unknown) {
        posix.eprint("looper: unknown command '{s}' (try: looper help)\n", .{parsed.positionals[0]});
        ctx.fail(2);
        ctx.flush();
        std.process.exit(ctx.exit_code);
    }
    if (cmd == .explain) {
        if (rest.len < 1) {
            posix.eprint("looper: explain needs a schedule\n", .{});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        }
        try cmds.cmdExplain(&ctx, rest[0]);
        ctx.flush();
        if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
        return;
    }

    // Resolve the default target chain: LOOPER_CRONTAB_FILE → local
    // crontab. `cli.buildTargets` is pure; here we feed it the hosts
    // file content (or empty when --all wasn't requested).
    var resolved = parsed;
    if (resolved.file_path.len == 0 and resolved.hosts.len == 0 and !resolved.use_all) {
        if (posix.getenv("LOOPER_CRONTAB_FILE")) |fp| resolved.file_path = fp;
    }
    // Compute the hosts-file path unconditionally so `doctor` can report
    // on it even when --all wasn't asked for.
    const hosts_cfg_path = if (posix.getenv("XDG_CONFIG_HOME")) |x|
        (std.fmt.allocPrint(a, "{s}/looper/hosts", .{x}) catch "")
    else
        (std.fmt.allocPrint(a, "{s}/.config/looper/hosts", .{posix.getenv("HOME") orelse "."}) catch "");
    var hosts_content: []const u8 = "";
    if (resolved.use_all) {
        hosts_content = target_mod.readFileAll(a, hosts_cfg_path) catch "";
        // `doctor` should still run so it can diagnose the missing/empty
        // hosts file; every other command needs at least one usable host.
        if (hosts_content.len == 0 and cmd != .doctor) {
            posix.eprint("looper: --all but no hosts in {s}\n", .{hosts_cfg_path});
            return;
        }
    }
    const targets = try cli.buildTargets(a, resolved, hosts_content);
    if (resolved.use_all and targets.len == 0 and cmd != .doctor) {
        posix.eprint("looper: --all but no usable hosts (every line is blank or a comment)\n", .{});
        return;
    }

    // `doctor` owns its own iteration: it must keep going past the per-
    // target read failures that the loop below treats as fatal-per-target.
    if (cmd == .doctor) {
        try cmds.cmdDoctor(&ctx, targets, hosts_cfg_path, resolved.use_all);
        ctx.flush();
        if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
        return;
    }

    const multi = targets.len > 1;
    for (targets) |t| {
        if (multi) ctx.emit("{s}{s}=== {s} ==={s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.BLUE), t.label(a), ctx.k(colors.RESET) });
        // For remote targets, the same ssh round-trip also fetches the
        // target's TZ (sentinel-split). Local/file return tz=null and we
        // resolve controller TZ here.
        const rr = target_mod.readCrontabAndTz(a, t, !ctx.no_target_tz) catch |e| {
            posix.eprint("looper: cannot read crontab on {s}: {s}\n", .{ t.label(a), @errorName(e) });
            if (e == target_mod.BackendError.Unavailable) posix.eprint("  (is 'crontab'/'ssh' installed and reachable?)\n", .{});
            continue;
        };
        const content = rr.content;
        var tz: tz_mod.TzInfo = rr.tz orelse tz_mod.controllerTz(a);
        // Remote target whose probe failed → fall back to controller TZ
        // but tag it so fmtWhenIn appends "(controller-local)" and the
        // user is never misled.
        if (rr.tz == null and t.kind == .remote) tz.source = .controller_fallback;
        switch (cmd) {
            .ls => try cmds.cmdLs(&ctx, t, content, tz),
            .add => {
                if (rest.len < 2) {
                    posix.eprint("looper: add needs <schedule> <command>\n", .{});
                    ctx.fail(1);
                    break;
                }
                try cmds.cmdAdd(&ctx, t, content, rest[0], rest[1], parsed.want_id);
            },
            .edit => {
                if (rest.len < 1) {
                    posix.eprint("looper: edit needs an id (try: looper ls)\n", .{});
                    ctx.fail(2);
                    break;
                }
                if (parsed.new_schedule == null and parsed.new_command == null) {
                    posix.eprint("looper: edit needs --schedule and/or --command\n", .{});
                    posix.eprint("  example: looper edit {s} --schedule \"0 4 * * *\"\n", .{rest[0]});
                    ctx.fail(2);
                    break;
                }
                try cmds.cmdEdit(&ctx, t, content, rest[0], parsed.new_schedule, parsed.new_command);
            },
            .rm => {
                if (rest.len < 1) {
                    posix.eprint("looper: rm needs an id\n", .{});
                    ctx.fail(1);
                    break;
                }
                try cmds.cmdRm(&ctx, t, content, rest);
            },
            .enable => try cmds.cmdToggle(&ctx, t, content, rest, true),
            .disable => try cmds.cmdToggle(&ctx, t, content, rest, false),
            .show => {
                if (rest.len < 1) {
                    posix.eprint("looper: show needs an id\n", .{});
                    ctx.fail(1);
                    break;
                }
                try cmds.cmdShow(&ctx, t, content, rest[0], tz);
            },
            .run => {
                if (rest.len < 1) {
                    posix.eprint("looper: run needs an id\n", .{});
                    ctx.fail(1);
                    break;
                }
                try cmds.cmdRun(&ctx, t, content, rest[0]);
            },
            .import => try cmds.cmdImport(&ctx, t, content),
            .backup => try cmds.cmdBackup(&ctx, t, content),
            .restore => try cmds.cmdRestore(&ctx, t, content, if (rest.len > 0) rest[0] else null),
            else => {},
        }
        if (multi) ctx.emit("\n", .{});
        ctx.flush();
    }
    ctx.flush();
    if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
}

// Force every module into the test binary's compile graph so its
// inline `test "..."` blocks are discovered. `zig build test` runs
// only what it can prove is reachable; `pub fn main` doesn't execute
// during the test build, so anything referenced solely from `main`
// would otherwise be skipped — silently leaving most modules untested.
test {
    _ = @import("posix.zig");
    _ = @import("ctx.zig");
    _ = @import("cli.zig");
    _ = @import("commands.zig");
    _ = @import("tz.zig");
    _ = @import("tz_probe.zig");
    _ = @import("cron/schedule.zig");
    _ = @import("cron/next_run.zig");
    _ = @import("cron/humanize.zig");
    _ = @import("cron/nlp.zig");
    _ = @import("crontab/model.zig");
    _ = @import("crontab/target.zig");
    _ = @import("crontab/backup.zig");
    _ = @import("ui/display.zig");
    _ = @import("ui/diff.zig");
    _ = @import("ui/help.zig");
    _ = @import("ui/colors.zig");
}
