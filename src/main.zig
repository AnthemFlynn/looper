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
const lock_mod = @import("lock.zig");

// Adding a new verb? Three places to update in lock-step:
//   1. This enum
//   2. `parseCmd`'s string→Cmd map (below)
//   3. `isMutating` if the verb writes the crontab — the lock dispatch
//      relies on it being correctly classified or concurrent writers
//      will silently race.
// A future refactor could collapse (1)+(2)+(3) into a single comptime
// table; deferred until the third dimension forces the issue.
const Cmd = enum { ls, add, edit, rm, enable, disable, show, run, explain, import, backup, backups, restore, doctor, once, runs, exec, history, last, apply, plan, version, help, unknown };

fn parseCmd(s: []const u8) Cmd {
    // Note: `set` aliases `edit` (the partial-update command), not `add`.
    // Previously `set` was an undocumented alias for `add`; redirecting
    // it to `edit` makes the natural reading "set the schedule of X to
    // Y" do the smarter thing — no positional re-statement of the other
    // field, so the command users don't want to change can't drift.
    //
    // `backup` (singular) creates one snapshot; `backups` (plural) lists
    // them or, with the `prune` subcommand, removes older ones. The two
    // are distinct verbs by design — `backup` is the side-effect, and
    // `backups` is the inventory.
    //
    // `_exec` is the internal cron-invoked wrapper for one-shot and
    // capture-enabled jobs. Underscore-prefixed and hidden from --help;
    // not in the regular map so a user typing 'exec' doesn't accidentally
    // discover it.
    if (std.mem.eql(u8, s, "_exec")) return .exec;
    const map = .{
        .{ "ls", Cmd.ls },           .{ "list", Cmd.ls },         .{ "add", Cmd.add },         .{ "edit", Cmd.edit },
        .{ "set", Cmd.edit },        .{ "rm", Cmd.rm },           .{ "remove", Cmd.rm },       .{ "delete", Cmd.rm },
        .{ "enable", Cmd.enable },   .{ "disable", Cmd.disable }, .{ "show", Cmd.show },       .{ "run", Cmd.run },
        .{ "explain", Cmd.explain }, .{ "import", Cmd.import },   .{ "backup", Cmd.backup },   .{ "backups", Cmd.backups },
        .{ "restore", Cmd.restore }, .{ "doctor", Cmd.doctor },   .{ "once", Cmd.once },       .{ "runs", Cmd.runs },
        .{ "history", Cmd.history }, .{ "last", Cmd.last },
        .{ "apply", Cmd.apply },     .{ "plan", Cmd.plan },
        .{ "version", Cmd.version }, .{ "help", Cmd.help },
    };
    inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return .unknown;
}

/// Predicate used by the per-target loop to decide whether to acquire
/// the cross-caller lock (v0.2 #8). Read-only verbs don't take it —
/// serializing concurrent readers would be a regression for no benefit.
/// `plan` is dry-run by definition, so it's read-only too; `apply` /
/// `add` / `edit` / `rm` / `enable` / `disable` / `restore` / `import` /
/// `backup` / `backups prune` all rewrite the crontab and need it.
fn isMutating(cmd: Cmd) bool {
    return switch (cmd) {
        .add, .edit, .rm, .enable, .disable, .import, .backup, .backups, .restore, .apply => true,
        else => false,
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = ctx_mod.Ctx{ .a = a };
    ctx.color = c.isatty(1) != 0 and posix.getenv("NO_COLOR") == null;

    const argv = try init.args.toSlice(a);
    var parsed = try cli.parseArgv(a, argv, &ctx);
    if (parsed.bad_option) |bad| {
        posix.eprint("looper: unknown option '{s}' (try: looper help)\n", .{bad});
        ctx.fail(2);
        ctx.flush();
        std.process.exit(ctx.exit_code);
    }
    // `--as` flag wins; otherwise fall back to LOOPER_AS env. Agents
    // typically export the env once and use the flag only for ad-hoc
    // overrides. Validated through the same predicate so an env value
    // with whitespace can't smuggle invalid bytes into the marker.
    if (parsed.as == null) {
        if (posix.getenv("LOOPER_AS")) |v| {
            if (!cli.isValidPrincipal(v)) {
                posix.eprint("looper: LOOPER_AS='{s}' contains whitespace, '=', or unprintable bytes — refusing to use as a principal\n", .{v});
                ctx.fail(2);
                ctx.flush();
                std.process.exit(ctx.exit_code);
            }
            parsed.as = v;
        }
    }
    // JSON-first: piped stdout (non-TTY) auto-enables --json so agents
    // never have to remember the flag. Explicit `--json` on the CLI has
    // already set ctx.json above; TTY callers see the human format.
    if (!ctx.json and c.isatty(1) == 0) ctx.json = true;

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

    // `_exec` is cron-invoked: it doesn't read a crontab up-front; it
    // runs the wrapped command, records the run, and (if --once)
    // removes the source job. Local-target by definition since cron
    // fires the local user's crontab. The positional argv after `--`
    // is the user's command — passed through verbatim.
    //
    // `--owner` is overloaded here vs. the filter semantics in
    // ls/runs ls: in the _exec context it carries the source job's
    // `created_by` forward from the wrapper line so the resulting
    // run record can be queried by `runs ls --owner`. The commands
    // are disjoint so the reuse is unambiguous in practice.
    if (cmd == .exec) {
        try cmds.cmdExecWithOwner(
            &ctx,
            parsed.run_id orelse "",
            parsed.source_id,
            parsed.owner,
            parsed.timeout_secs,
            parsed.target_label,
            parsed.once_flag,
            rest,
        );
        ctx.flush();
        if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
        return;
    }

    // `once <when> <cmd>` schedules a one-shot job. Local-only in v1
    // (Phase A scope decision). Reads the local crontab itself rather
    // than going through the per-target loop, so the diagnostic for
    // a missing/unreachable crontab is more useful here.
    if (cmd == .once) {
        if (rest.len < 2) {
            posix.eprint("looper: once needs <when> <command>\n", .{});
            posix.eprint("  example: looper once \"in 5 min\" \"echo hello\"\n", .{});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        }
        // v1 punt: -f / -H / --all silently ignored would be confusing
        // (the writes happen to local crontab no matter what). Reject
        // explicitly so the user gets a clear "not yet supported" error.
        if (resolved.file_path.len > 0 or resolved.hosts.len > 0 or resolved.use_all) {
            posix.eprint("looper: once is local-target only in v1 (remote/file one-shots aren't yet supported)\n", .{});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        }
        const t: target_mod.Target = .{ .kind = .local };
        const content = target_mod.readCrontab(a, t) catch "";
        try cmds.cmdScheduleOnce(&ctx, t, content, rest[0], rest[1], .{
            .want_id = parsed.want_id,
            .timeout_secs = parsed.timeout_secs,
        });
        ctx.flush();
        if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
        return;
    }

    // `history <id>` and `last <id>` query run records under
    // state_dir/runs/, filtered by source_id. Local-only by definition
    // — there's no remote analog because state_dir is per-machine.
    if (cmd == .history or cmd == .last) {
        if (rest.len < 1) {
            posix.eprint("looper: {s} needs an id (try: looper ls)\n", .{parsed.positionals[0]});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        }
        if (cmd == .history) try cmds.cmdHistory(&ctx, rest[0]) else try cmds.cmdLast(&ctx, rest[0]);
        ctx.flush();
        if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
        return;
    }

    // `runs ls | show <id> | prune` queries / manages the local run
    // records under state_dir/runs/. No target iteration — state_dir
    // is per-machine.
    if (cmd == .runs) {
        if (rest.len == 0) {
            posix.eprint("looper: runs needs a subcommand (ls, show <id>, or prune)\n", .{});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        }
        const sub = rest[0];
        if (std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "list")) {
            // Read local crontab so cmdRunsLs can synthesize pending
            // records for one-shots not yet fired. Empty on read failure
            // → pending detection skipped, executed records still shown.
            const local: target_mod.Target = .{ .kind = .local };
            const content = target_mod.readCrontab(a, local) catch "";
            var filter: cmds.RunsFilter = .{};
            if (parsed.status_filter) |s| filter.status = cmds.parseRunsStatusFilter(s);
            if (parsed.owner) |o| filter.owner = o;
            try cmds.cmdRunsLs(&ctx, content, filter);
        } else if (std.mem.eql(u8, sub, "show")) {
            if (rest.len < 2) {
                posix.eprint("looper: runs show needs a run_id (try: looper runs ls)\n", .{});
                ctx.fail(2);
                ctx.flush();
                std.process.exit(ctx.exit_code);
            }
            try cmds.cmdRunsShow(&ctx, rest[1], parsed.full_output);
        } else if (std.mem.eql(u8, sub, "prune")) {
            try cmds.cmdRunsPrune(&ctx, parsed.older_than_secs);
        } else {
            posix.eprint("looper: unknown runs subcommand '{s}' (try: looper runs ls, runs show <id>, runs prune)\n", .{sub});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        }
        ctx.flush();
        if (ctx.exit_code != 0) std.process.exit(ctx.exit_code);
        return;
    }

    const multi = targets.len > 1;
    // Suppress per-target headers (and the trailing blank line below)
    // in JSON mode — they break parsability. Each JSON document carries
    // its own `target` field for disambiguation.
    const visual_multi = multi and !ctx.json;
    // Per-target concurrency knob (v0.2 #4). The flag is accepted for
    // forward compatibility but v0.2's dispatch loop is sequential —
    // the acceptance contract is deterministic per-target ordering,
    // which sequential trivially satisfies. When the operator asked
    // for real parallelism (`-j N` with N > 1), emit a one-line stderr
    // hint so they aren't misled about what shipped. `--quiet`
    // suppresses the hint, matching the convention used by
    // `--check-command` (commands/mutate.zig:72).
    if (parsed.jobs) |n| {
        if (n > 1 and !ctx.quiet) {
            posix.eprint("looper: -j {d} accepted but v0.2 fan-out is sequential (bounded worker pool lands in v0.3)\n", .{n});
        }
    }
    for (targets) |t| {
        if (visual_multi) ctx.emit("{s}{s}=== {s} ==={s}\n", .{ ctx.k(colors.BOLD), ctx.k(colors.BLUE), t.label(a), ctx.k(colors.RESET) });
        // Cross-caller lock (v0.2 #8): only held around mutating
        // commands. Read-only verbs (ls/show/explain) don't need it
        // and acquiring would serialize concurrent readers for no
        // benefit. The lock is taken BEFORE the crontab read so the
        // read-modify-write window is fully covered.
        var lock = if (isMutating(cmd)) lock_mod.acquire(a, t) else lock_mod.Lock{};
        defer lock.release();
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
            .ls => try cmds.cmdLs(&ctx, t, content, tz, .{ .owner = parsed.owner }),
            .add => {
                if (rest.len < 2) {
                    posix.eprint("looper: add needs <schedule> <command>\n", .{});
                    ctx.fail(1);
                    break;
                }
                try cmds.cmdAdd(&ctx, t, content, rest[0], rest[1], parsed.want_id, .{
                    .check_command = parsed.check_command,
                    .capture = parsed.capture,
                    .no_wrap = parsed.no_wrap,
                    .as = parsed.as,
                });
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
                try cmds.cmdEdit(&ctx, t, content, rest[0], parsed.new_schedule, parsed.new_command, .{ .as = parsed.as });
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
            .backups => {
                // Subcommand split: `backups` alone is the listing; `backups
                // prune` is the only mutator and demands --keep. Anything
                // else under `backups <x>` is a usage error (so we don't
                // silently treat a typo as a list request).
                if (rest.len == 0) {
                    try cmds.cmdBackups(&ctx, t);
                } else if (std.mem.eql(u8, rest[0], "prune")) {
                    const keep = parsed.keep orelse {
                        posix.eprint("looper: 'backups prune' needs --keep <N> (e.g. 'looper backups prune --keep 20')\n", .{});
                        ctx.fail(2);
                        break;
                    };
                    try cmds.cmdBackupsPrune(&ctx, t, keep);
                } else {
                    posix.eprint("looper: unknown backups subcommand '{s}' (try: looper backups, looper backups prune --keep N)\n", .{rest[0]});
                    ctx.fail(2);
                    break;
                }
            },
            .restore => try cmds.cmdRestore(&ctx, t, content, if (rest.len > 0) rest[0] else null, parsed.from_stamp),
            .apply => {
                if (rest.len < 1) {
                    posix.eprint("looper: apply needs <spec.toml>\n", .{});
                    posix.eprint("  example: looper -f /tmp/c apply jobs.toml\n", .{});
                    ctx.fail(2);
                    break;
                }
                try cmds.cmdApply(&ctx, t, content, rest[0], .{ .as = parsed.as });
            },
            .plan => {
                if (rest.len < 1) {
                    posix.eprint("looper: plan needs <spec.toml>\n", .{});
                    posix.eprint("  example: looper -f /tmp/c plan jobs.toml\n", .{});
                    ctx.fail(2);
                    break;
                }
                try cmds.cmdPlan(&ctx, t, content, rest[0], .{ .as = parsed.as });
            },
            else => {},
        }
        if (visual_multi) ctx.emit("\n", .{});
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
    _ = @import("spec.zig");
    _ = @import("lock.zig");
}
