//! Pure CLI parsing primitives — argv → ParsedArgs and parsed args →
//! target list. Lifted out of `main.zig` so they can be exercised by
//! unit tests; `main` becomes a thin orchestration shell.
//!
//! The Ctx flags (color, json, dry_run, yes, quiet) are mutated in
//! place by `parseArgv` — they are user-facing knobs that belong to the
//! same `Ctx` that flows through the rest of the run. Returning them
//! in `ParsedArgs` instead would just duplicate state.
const std = @import("std");
const ctx_mod = @import("ctx.zig");
const target_mod = @import("crontab/target.zig");
const Target = target_mod.Target;

pub const ParsedArgs = struct {
    positionals: [][]const u8,
    hosts: [][]const u8,
    use_all: bool,
    user: []const u8,
    file_path: []const u8,
    want_id: ?[]const u8,
    force_help: bool,
    /// Set to the offending arg when an unknown option (e.g. `--frob`)
    /// is encountered. Parsing stops at the first unknown option so
    /// later flags don't silently take effect. `main` checks this and
    /// emits the diagnostic + exit 2.
    bad_option: ?[]const u8,
};

/// Parse `argv` (with `argv[0]` being the program name, skipped) into a
/// ParsedArgs bag. Flag booleans on `ctx` are mutated in place. On an
/// unknown option, `bad_option` is set and parsing stops; the caller
/// is responsible for the diagnostic + exit.
pub fn parseArgv(a: std.mem.Allocator, argv: []const []const u8, ctx: *ctx_mod.Ctx) !ParsedArgs {
    var positionals: std.ArrayList([]const u8) = .empty;
    var hosts: std.ArrayList([]const u8) = .empty;
    var p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &[_][]const u8{},
        .use_all = false,
        .user = "",
        .file_path = "",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        // `--` ends option parsing; remaining argv becomes positional.
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < argv.len) : (i += 1) try positionals.append(a, argv[i]);
            break;
        }
        // Options that take a value.
        if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < argv.len) try hosts.append(a, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i < argv.len) p.user = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < argv.len) p.file_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--id")) {
            i += 1;
            if (i < argv.len) p.want_id = argv[i];
            continue;
        }
        // Boolean flags.
        if (std.mem.eql(u8, arg, "--all")) {
            p.use_all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            ctx.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            ctx.yes = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            ctx.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            ctx.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-color")) {
            ctx.color = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-target-tz")) {
            ctx.no_target_tz = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            p.force_help = true;
            continue;
        }
        // Unknown option (starts with `-`, not a negative number).
        if (arg.len > 1 and arg[0] == '-' and !std.ascii.isDigit(arg[1])) {
            p.bad_option = arg;
            p.positionals = try positionals.toOwnedSlice(a);
            p.hosts = try hosts.toOwnedSlice(a);
            return p;
        }
        try positionals.append(a, arg);
    }

    p.positionals = try positionals.toOwnedSlice(a);
    p.hosts = try hosts.toOwnedSlice(a);
    return p;
}

/// Build the target list from parsed args. `hosts_file_content` is the
/// contents of `~/.config/looper/hosts` when `parsed.use_all` is set —
/// pulled in by the caller so this function stays pure / testable.
/// Returns an empty list when --all is set but `hosts_file_content`
/// has no usable lines; `main` checks for that and emits a diagnostic.
pub fn buildTargets(
    a: std.mem.Allocator,
    parsed: ParsedArgs,
    hosts_file_content: []const u8,
) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    if (parsed.use_all) {
        var it = std.mem.splitScalar(u8, hosts_file_content, '\n');
        while (it.next()) |line| {
            const h = std.mem.trim(u8, line, " \t\r");
            if (h.len == 0 or h[0] == '#') continue;
            try targets.append(a, .{ .kind = .remote, .host = h, .user = parsed.user });
        }
    } else if (parsed.hosts.len > 0) {
        for (parsed.hosts) |h| try targets.append(a, .{ .kind = .remote, .host = h, .user = parsed.user });
    } else if (parsed.file_path.len > 0) {
        try targets.append(a, .{ .kind = .file, .path = parsed.file_path });
    } else {
        try targets.append(a, .{ .kind = .local, .user = parsed.user });
    }
    return targets.toOwnedSlice(a);
}

const testing = std.testing;

fn newCtx(a: std.mem.Allocator) ctx_mod.Ctx {
    return ctx_mod.Ctx{ .a = a };
}

test "parseArgv defaults: only program name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{"looper"};
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(usize, 0), p.positionals.len);
    try testing.expectEqual(@as(usize, 0), p.hosts.len);
    try testing.expect(!p.use_all);
    try testing.expect(!p.force_help);
    try testing.expect(!ctx.dry_run);
    try testing.expect(!ctx.yes);
}

test "parseArgv collects positionals and a single host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "-H", "nas", "ls" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(usize, 1), p.positionals.len);
    try testing.expectEqualStrings("ls", p.positionals[0]);
    try testing.expectEqual(@as(usize, 1), p.hosts.len);
    try testing.expectEqualStrings("nas", p.hosts[0]);
}

test "parseArgv -H repeatable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "-H", "nas", "-H", "media", "ls" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(usize, 2), p.hosts.len);
    try testing.expectEqualStrings("nas", p.hosts[0]);
    try testing.expectEqualStrings("media", p.hosts[1]);
}

test "parseArgv long-form flags mutate ctx" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    ctx.color = true;
    const argv = [_][]const u8{ "looper", "--dry-run", "--yes", "--json", "--quiet", "--no-color", "ls" };
    _ = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(ctx.dry_run);
    try testing.expect(ctx.yes);
    try testing.expect(ctx.json);
    try testing.expect(ctx.quiet);
    try testing.expect(!ctx.color);
}

test "parseArgv --file captures path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "-f", "/tmp/c", "add", "0 3 * * *", "/bin/x" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("/tmp/c", p.file_path);
    try testing.expectEqual(@as(usize, 3), p.positionals.len);
    try testing.expectEqualStrings("add", p.positionals[0]);
}

test "parseArgv --id and --user" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "-u", "ops", "--id", "backup", "add", "0 3 * * *", "/bin/x" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("ops", p.user);
    try testing.expect(p.want_id != null);
    try testing.expectEqualStrings("backup", p.want_id.?);
}

test "parseArgv -- ends option parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--", "-q", "--json" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    // -q and --json after `--` are positional, not flags
    try testing.expect(!ctx.quiet);
    try testing.expect(!ctx.json);
    try testing.expectEqual(@as(usize, 3), p.positionals.len);
    try testing.expectEqualStrings("-q", p.positionals[1]);
    try testing.expectEqualStrings("--json", p.positionals[2]);
}

test "parseArgv unknown option sets bad_option and stops parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "--frobnicate", "--json", "ls" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("--frobnicate", p.bad_option.?);
    // Parser must stop at the bad option, NOT silently apply later flags.
    try testing.expect(!ctx.json);
}

test "parseArgv --help sets force_help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "--help" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.force_help);
}

test "parseArgv negative-number positional is not an unknown option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    // Hypothetical: a job command starting with "-1" should pass through.
    const argv = [_][]const u8{ "looper", "explain", "-1" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(usize, 2), p.positionals.len);
    try testing.expectEqualStrings("-1", p.positionals[1]);
}

test "buildTargets default = local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &[_][]const u8{},
        .use_all = false,
        .user = "",
        .file_path = "",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };
    const targets = try buildTargets(arena.allocator(), p, "");
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(target_mod.TargetKind.local, targets[0].kind);
}

test "buildTargets file path → one file target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &[_][]const u8{},
        .use_all = false,
        .user = "",
        .file_path = "/tmp/c",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };
    const targets = try buildTargets(arena.allocator(), p, "");
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(target_mod.TargetKind.file, targets[0].kind);
    try testing.expectEqualStrings("/tmp/c", targets[0].path);
}

test "buildTargets -H hosts → one remote per host, sharing user" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var hosts = [_][]const u8{ "nas", "media" };
    const p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &hosts,
        .use_all = false,
        .user = "ops",
        .file_path = "",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };
    const targets = try buildTargets(arena.allocator(), p, "");
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqualStrings("nas", targets[0].host);
    try testing.expectEqualStrings("ops", targets[0].user);
    try testing.expectEqualStrings("media", targets[1].host);
}

test "buildTargets --all parses hosts file, ignores blank/comment lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &[_][]const u8{},
        .use_all = true,
        .user = "",
        .file_path = "",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };
    const hosts_file =
        \\# fleet hosts
        \\pi@nas
        \\
        \\pi@media
        \\# disabled-host
        \\deploy@web1
    ;
    const targets = try buildTargets(arena.allocator(), p, hosts_file);
    try testing.expectEqual(@as(usize, 3), targets.len);
    try testing.expectEqualStrings("pi@nas", targets[0].host);
    try testing.expectEqualStrings("pi@media", targets[1].host);
    try testing.expectEqualStrings("deploy@web1", targets[2].host);
}

test "buildTargets --all empty hosts file → empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &[_][]const u8{},
        .use_all = true,
        .user = "",
        .file_path = "",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };
    const targets = try buildTargets(arena.allocator(), p, "# only comments\n\n");
    try testing.expectEqual(@as(usize, 0), targets.len);
}

test "buildTargets --all + -u applies user to every remote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p: ParsedArgs = .{
        .positionals = &[_][]const u8{},
        .hosts = &[_][]const u8{},
        .use_all = true,
        .user = "deploy",
        .file_path = "",
        .want_id = null,
        .force_help = false,
        .bad_option = null,
    };
    const targets = try buildTargets(arena.allocator(), p, "nas\nmedia\n");
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqualStrings("deploy", targets[0].user);
    try testing.expectEqualStrings("deploy", targets[1].user);
}
