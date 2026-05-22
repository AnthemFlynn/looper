//! Entry point: argv parsing, target list construction, per-target
//! dispatch loop. Each subcommand lives in `commands.zig`.
const std = @import("std");
const posix = @import("posix.zig");
const c = posix.c;
const ctx_mod = @import("ctx.zig");
const cmds = @import("commands.zig");
const help_mod = @import("ui/help.zig");
const target_mod = @import("crontab/target.zig");
const Target = target_mod.Target;

const Cmd = enum { ls, add, rm, enable, disable, show, run, explain, import, backup, restore, version, help, unknown };

fn parseCmd(s: []const u8) Cmd {
    const map = .{
        .{ "ls", Cmd.ls },         .{ "list", Cmd.ls },         .{ "add", Cmd.add },     .{ "set", Cmd.add },
        .{ "rm", Cmd.rm },         .{ "remove", Cmd.rm },       .{ "delete", Cmd.rm },
        .{ "enable", Cmd.enable }, .{ "disable", Cmd.disable }, .{ "show", Cmd.show },
        .{ "run", Cmd.run },       .{ "explain", Cmd.explain }, .{ "import", Cmd.import },
        .{ "backup", Cmd.backup }, .{ "restore", Cmd.restore }, .{ "version", Cmd.version }, .{ "help", Cmd.help },
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

    var positionals: std.ArrayList([]const u8) = .empty;
    var hosts: std.ArrayList([]const u8) = .empty;
    var use_all = false;
    var user: []const u8 = "";
    var file_path: []const u8 = "";
    var want_id: ?[]const u8 = null;
    var force_help = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < argv.len) : (i += 1) try positionals.append(a, argv[i]);
            break;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < argv.len) try hosts.append(a, argv[i]);
        } else if (std.mem.eql(u8, arg, "--all")) use_all = true
        else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i < argv.len) user = argv[i];
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < argv.len) file_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--id")) {
            i += 1;
            if (i < argv.len) want_id = argv[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) ctx.dry_run = true
        else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) ctx.yes = true
        else if (std.mem.eql(u8, arg, "--json")) ctx.json = true
        else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) ctx.quiet = true
        else if (std.mem.eql(u8, arg, "--no-color")) ctx.color = false
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) force_help = true
        else if (arg.len > 1 and arg[0] == '-' and !std.ascii.isDigit(arg[1])) {
            posix.eprint("looper: unknown option '{s}' (try: looper help)\n", .{arg});
            ctx.fail(2);
            ctx.flush();
            std.process.exit(ctx.exit_code);
        } else try positionals.append(a, arg);
    }

    if (force_help or positionals.items.len == 0) {
        help_mod.printHelp(&ctx);
        ctx.flush();
        return;
    }
    const cmd = parseCmd(positionals.items[0]);
    const rest = positionals.items[1..];
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
        posix.eprint("looper: unknown command '{s}' (try: looper help)\n", .{positionals.items[0]});
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

    if (file_path.len == 0 and hosts.items.len == 0 and !use_all) {
        if (posix.getenv("LOOPER_CRONTAB_FILE")) |fp| file_path = fp;
    }
    var targets: std.ArrayList(Target) = .empty;
    if (use_all) {
        const cfg = if (posix.getenv("XDG_CONFIG_HOME")) |x| (std.fmt.allocPrint(a, "{s}/looper/hosts", .{x}) catch "") else (std.fmt.allocPrint(a, "{s}/.config/looper/hosts", .{posix.getenv("HOME") orelse "."}) catch "");
        const body = target_mod.readFileAll(a, cfg) catch "";
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            const h = std.mem.trim(u8, line, " \t\r");
            if (h.len == 0 or h[0] == '#') continue;
            try targets.append(a, .{ .kind = .remote, .host = h, .user = user });
        }
        if (targets.items.len == 0) {
            posix.eprint("looper: --all but no hosts in {s}\n", .{cfg});
            return;
        }
    } else if (hosts.items.len > 0) {
        for (hosts.items) |h| try targets.append(a, .{ .kind = .remote, .host = h, .user = user });
    } else if (file_path.len > 0) {
        try targets.append(a, .{ .kind = .file, .path = file_path });
    } else try targets.append(a, .{ .kind = .local, .user = user });

    const multi = targets.items.len > 1;
    for (targets.items) |t| {
        if (multi) ctx.emit("{s}{s}=== {s} ==={s}\n", .{ ctx.k(ctx_mod.BOLD), ctx.k(ctx_mod.BLUE), t.label(a), ctx.k(ctx_mod.RESET) });
        const content = target_mod.readCrontab(a, t) catch |e| {
            posix.eprint("looper: cannot read crontab on {s}: {s}\n", .{ t.label(a), @errorName(e) });
            if (e == target_mod.BackendError.Unavailable) posix.eprint("  (is 'crontab'/'ssh' installed and reachable?)\n", .{});
            continue;
        };
        switch (cmd) {
            .ls => try cmds.cmdLs(&ctx, t, content),
            .add => {
                if (rest.len < 2) {
                    posix.eprint("looper: add needs <schedule> <command>\n", .{});
                    ctx.fail(1);
                    break;
                }
                try cmds.cmdAdd(&ctx, t, content, rest[0], rest[1], want_id);
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
                try cmds.cmdShow(&ctx, t, content, rest[0]);
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
