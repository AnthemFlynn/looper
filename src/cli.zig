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
    /// `edit` partial-update flags. Either, both, or neither may be
    /// supplied; `edit` requires at least one, other commands ignore
    /// them. Stored on ParsedArgs (not Ctx) because they're command
    /// arguments, not global UI toggles.
    new_schedule: ?[]const u8,
    new_command: ?[]const u8,
    /// `restore --from <stamp>`: a full or substring backup stamp. The
    /// command resolves it against the target's backup directory via
    /// `findByStamp`. Mutually exclusive with the positional path; we
    /// surface that conflict in `cmdRestore`.
    from_stamp: ?[]const u8,
    /// `backups prune --keep <N>`: number of newest backups to retain.
    /// `null` means the flag wasn't supplied; `prune` rejects that with
    /// a usage error rather than picking a default that might delete
    /// more than the user expected.
    keep: ?usize,
    /// `add --check-command`: opt-in preflight that warns when the
    /// command's first executable token isn't found on the target.
    /// Non-blocking — the add still proceeds; the user just gets the
    /// "you probably need an absolute path / your PATH is different
    /// under cron" heads-up before learning about it from a silent
    /// mail spool tomorrow morning.
    check_command: bool,
    /// `add --capture`: wrap the cron payload in `looper _exec` so
    /// each fire captures stdout/stderr + records exit code under
    /// state_dir/runs/. Marker gains `capture=1` and `wrapper_bin=<path>`.
    capture: bool,
    /// `_exec --run-id <id>`: identifies the run record this invocation
    /// will write to under state_dir/runs/<run_id>/. One-shots set this
    /// at add-time (the "series anchor"); the manual `looper run` path
    /// generates one. For recurring captured jobs the wrapper line
    /// omits this and `_exec` synthesizes a fresh id from `--source-id`.
    run_id: ?[]const u8,
    /// `_exec --source-id <id>`: looper job id to remove on completion
    /// when --once is set. Skipped if absent (no self-removal).
    source_id: ?[]const u8,
    /// `_exec --timeout-secs N`: kill child after N seconds. Null = wait
    /// indefinitely. Parsed as u32 so 0 is a valid "kill immediately"
    /// (mostly only useful for tests).
    timeout_secs: ?u32,
    /// `_exec --target-label <L>`: display label recorded on the run
    /// record. Optional — defaults to "local" when unset.
    target_label: ?[]const u8,
    /// `_exec --once`: after the child exits, remove the source job
    /// from the local crontab. Without this, _exec just records the
    /// run (used by capture-enabled recurring jobs).
    once_flag: bool,
    /// `runs ls --status <s>`: filter records by lifecycle status.
    /// Raw string; commands/runs parses via parseStatusFilter.
    status_filter: ?[]const u8,
    /// `runs prune --older-than <secs>`: cutoff in seconds. v1 takes
    /// an integer; a future revision could accept duration syntax
    /// like "30d" or "1w".
    older_than_secs: ?i64,
    /// `runs show --full`: don't cap inline stdout/stderr at the
    /// usual 8 KiB. For very large captures the user can also read
    /// the files directly under state_dir/runs/<id>/.
    full_output: bool,
    /// `--as <principal>`: declares the actor (typically an agent
    /// name) performing this command. Sets `created_by` on `add`,
    /// updates `last_modified_by` on `edit`. Used by `_exec` to
    /// stamp run records. Falls back to `LOOPER_AS` env var, then
    /// to null (legacy behavior, marker omitted).
    as: ?[]const u8,
    /// `ls --owner <principal>` / `runs ls --owner <principal>`:
    /// filter results to jobs (or runs) whose `created_by` matches.
    owner: ?[]const u8,
    /// `add --no-wrap`: skip the default wrap-by-default capture
    /// wrapper. v0.1 promotes wrapping from opt-in (--capture) to
    /// opt-out so silent cron failure becomes detectable by default.
    no_wrap: bool,
    /// `-j N` / `--jobs N`: per-target concurrency cap for multi-target
    /// fan-out (v0.2 #4). Accepted as a CLI surface; the v0.2 dispatch
    /// loop is still sequential, which trivially satisfies the
    /// "deterministic per-target output order" contract the acceptance
    /// script pins. Bounded thread pool lands in a follow-up commit when
    /// per-target probes become the dominant latency.
    jobs: ?usize,
    force_help: bool,
    /// Set to the offending arg when an unknown option (e.g. `--frob`)
    /// is encountered. Parsing stops at the first unknown option so
    /// later flags don't silently take effect. `main` checks this and
    /// emits the diagnostic + exit 2.
    bad_option: ?[]const u8,
};

/// Match `--name=value` style. Returns the value substring if `arg` is
/// exactly `name=<value>` (POSIX getopt equals-form). Pure helper; the
/// space-form `--name value` is still handled by the surrounding
/// `std.mem.eql` checks. Both forms must be supported because cron-
/// generated invocations (and external scripts) commonly use equals.
fn equalsValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (arg.len > name.len + 1 and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') {
        return arg[name.len + 1 ..];
    }
    return null;
}

/// Principal values (`--as`, `--owner`) are stored in the `#looper#`
/// marker, which is whitespace-tokenized on parse. Allowing whitespace,
/// `=`, or unprintable bytes would silently corrupt the round-trip:
/// a name like "deploy agent" gets serialized as
/// `created_by=deploy agent`, which the parser splits on space and
/// truncates to "deploy". Rejecting at CLI ingress is simpler than
/// adding escape syntax to the marker format and keeps existing
/// crontabs byte-stable.
pub fn isValidPrincipal(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |ch| {
        if (ch == '=') return false;
        if (ch <= 0x20 or ch == 0x7f) return false; // controls + space
    }
    return true;
}

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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
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
        // Options that take a value. Each accepts BOTH the POSIX
        // space-form (`--foo value`) and the equals-form (`--foo=value`).
        // Cron-generated invocations and many external tools use equals;
        // a parser supporting only spaces silently rejected them.
        if (equalsValue(arg, "--host")) |v| { try hosts.append(a, v); continue; }
        if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < argv.len) try hosts.append(a, argv[i]);
            continue;
        }
        if (equalsValue(arg, "--user")) |v| { p.user = v; continue; }
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i < argv.len) p.user = argv[i];
            continue;
        }
        if (equalsValue(arg, "--file")) |v| { p.file_path = v; continue; }
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < argv.len) p.file_path = argv[i];
            continue;
        }
        if (equalsValue(arg, "--id")) |v| { p.want_id = v; continue; }
        if (std.mem.eql(u8, arg, "--id")) {
            i += 1;
            if (i < argv.len) p.want_id = argv[i];
            continue;
        }
        if (equalsValue(arg, "--schedule")) |v| { p.new_schedule = v; continue; }
        if (std.mem.eql(u8, arg, "--schedule")) {
            i += 1;
            if (i < argv.len) p.new_schedule = argv[i];
            continue;
        }
        if (equalsValue(arg, "--command")) |v| { p.new_command = v; continue; }
        if (std.mem.eql(u8, arg, "--command")) {
            i += 1;
            if (i < argv.len) p.new_command = argv[i];
            continue;
        }
        if (equalsValue(arg, "--from")) |v| { p.from_stamp = v; continue; }
        if (std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i < argv.len) p.from_stamp = argv[i];
            continue;
        }
        if (equalsValue(arg, "--keep")) |v| {
            p.keep = std.fmt.parseInt(usize, v, 10) catch {
                p.bad_option = v;
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            i += 1;
            if (i < argv.len) {
                // Reject non-integer values up-front so `--keep abc` is a
                // hard argv error rather than something the `prune` path
                // has to recover from. Out-of-range or negative values
                // are also surfaced here.
                p.keep = std.fmt.parseInt(usize, argv[i], 10) catch {
                    p.bad_option = argv[i];
                    p.positionals = try positionals.toOwnedSlice(a);
                    p.hosts = try hosts.toOwnedSlice(a);
                    return p;
                };
            }
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
        if (std.mem.eql(u8, arg, "--check-command")) {
            p.check_command = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--capture")) {
            p.capture = true;
            continue;
        }
        if (equalsValue(arg, "--run-id")) |v| { p.run_id = v; continue; }
        if (std.mem.eql(u8, arg, "--run-id")) {
            i += 1;
            if (i < argv.len) p.run_id = argv[i];
            continue;
        }
        if (equalsValue(arg, "--source-id")) |v| { p.source_id = v; continue; }
        if (std.mem.eql(u8, arg, "--source-id")) {
            i += 1;
            if (i < argv.len) p.source_id = argv[i];
            continue;
        }
        if (equalsValue(arg, "--timeout-secs")) |v| {
            p.timeout_secs = std.fmt.parseInt(u32, v, 10) catch {
                p.bad_option = v;
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-secs")) {
            i += 1;
            if (i < argv.len) {
                // Same up-front parse-or-fail pattern as --keep so a bogus
                // value is a hard argv error, not something _exec has to
                // recover from mid-execution.
                p.timeout_secs = std.fmt.parseInt(u32, argv[i], 10) catch {
                    p.bad_option = argv[i];
                    p.positionals = try positionals.toOwnedSlice(a);
                    p.hosts = try hosts.toOwnedSlice(a);
                    return p;
                };
            }
            continue;
        }
        if (equalsValue(arg, "--target-label")) |v| { p.target_label = v; continue; }
        if (std.mem.eql(u8, arg, "--target-label")) {
            i += 1;
            if (i < argv.len) p.target_label = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--once")) {
            p.once_flag = true;
            continue;
        }
        if (equalsValue(arg, "--status")) |v| { p.status_filter = v; continue; }
        if (std.mem.eql(u8, arg, "--status")) {
            i += 1;
            if (i < argv.len) p.status_filter = argv[i];
            continue;
        }
        if (equalsValue(arg, "--older-than")) |v| {
            p.older_than_secs = std.fmt.parseInt(i64, v, 10) catch {
                p.bad_option = v;
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--older-than")) {
            i += 1;
            if (i < argv.len) {
                p.older_than_secs = std.fmt.parseInt(i64, argv[i], 10) catch {
                    p.bad_option = argv[i];
                    p.positionals = try positionals.toOwnedSlice(a);
                    p.hosts = try hosts.toOwnedSlice(a);
                    return p;
                };
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--full")) {
            p.full_output = true;
            continue;
        }
        if (equalsValue(arg, "--as")) |v| {
            if (!isValidPrincipal(v)) {
                p.bad_option = v;
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            }
            p.as = v;
            continue;
        }
        if (std.mem.eql(u8, arg, "--as")) {
            i += 1;
            // Missing value (end-of-argv) and invalid characters both
            // surface through bad_option so main.zig's existing "unknown
            // option" diagnostic fires — silent provenance-stripping is
            // worse than a noisy error.
            if (i >= argv.len or !isValidPrincipal(argv[i])) {
                p.bad_option = if (i >= argv.len) "--as" else argv[i];
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            }
            p.as = argv[i];
            continue;
        }
        if (equalsValue(arg, "--owner")) |v| {
            if (!isValidPrincipal(v)) {
                p.bad_option = v;
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            }
            p.owner = v;
            continue;
        }
        if (std.mem.eql(u8, arg, "--owner")) {
            i += 1;
            if (i >= argv.len or !isValidPrincipal(argv[i])) {
                p.bad_option = if (i >= argv.len) "--owner" else argv[i];
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            }
            p.owner = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-wrap")) {
            p.no_wrap = true;
            continue;
        }
        if (equalsValue(arg, "--jobs")) |v| {
            p.jobs = std.fmt.parseInt(usize, v, 10) catch {
                p.bad_option = v;
                p.positionals = try positionals.toOwnedSlice(a);
                p.hosts = try hosts.toOwnedSlice(a);
                return p;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i < argv.len) {
                p.jobs = std.fmt.parseInt(usize, argv[i], 10) catch {
                    p.bad_option = argv[i];
                    p.positionals = try positionals.toOwnedSlice(a);
                    p.hosts = try hosts.toOwnedSlice(a);
                    return p;
                };
            }
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

test "parseArgv --schedule and --command captured independently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "edit", "db-backup", "--schedule", "0 4 * * *" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("0 4 * * *", p.new_schedule.?);
    try testing.expect(p.new_command == null);
}

test "parseArgv --command alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "edit", "db-backup", "--command", "/bin/new.sh" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("/bin/new.sh", p.new_command.?);
    try testing.expect(p.new_schedule == null);
}

test "parseArgv --from captures stamp argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "restore", "--from", "20260522T093015Z" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("20260522T093015Z", p.from_stamp.?);
}

test "parseArgv --keep N parses to usize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "backups", "prune", "--keep", "20" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(usize, 20), p.keep.?);
}

test "parseArgv --check-command sets the flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--check-command", "@daily", "/usr/local/bin/foo" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.check_command);
    try testing.expectEqual(@as(usize, 3), p.positionals.len);
    try testing.expectEqualStrings("add", p.positionals[0]);
}

test "parseArgv --capture sets the flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--capture", "@daily", "/usr/local/bin/backup.sh" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.capture);
}

test "parseArgv --capture default is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "@daily", "/bin/echo" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(!p.capture);
}

test "parseArgv --check-command default is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "@daily", "/usr/local/bin/foo" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(!p.check_command);
}

test "parseArgv --keep with non-numeric value sets bad_option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "backups", "prune", "--keep", "abc" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("abc", p.bad_option.?);
    try testing.expect(p.keep == null);
}

test "parseArgv both --schedule and --command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "edit", "db-backup", "--schedule", "@daily", "--command", "/bin/new.sh" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("@daily", p.new_schedule.?);
    try testing.expectEqualStrings("/bin/new.sh", p.new_command.?);
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

test "parseArgv --run-id captures value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--run-id", "abc123", "--", "/bin/echo", "hi" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("abc123", p.run_id.?);
}

test "parseArgv --source-id captures value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--source-id", "daily-backup" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("daily-backup", p.source_id.?);
}

test "parseArgv --timeout-secs parses to u32" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--timeout-secs", "300" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(?u32, 300), p.timeout_secs);
}

test "parseArgv --timeout-secs rejects non-numeric value as bad_option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--timeout-secs", "nope" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("nope", p.bad_option.?);
}

test "parseArgv --once sets the boolean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--once" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.once_flag);
}

test "parseArgv --once default is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(!p.once_flag);
}

test "parseArgv --target-label captures value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--target-label", "local" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("local", p.target_label.?);
}

test "parseArgv accepts --name=value form (cron-generated invocations)" {
    // Cron emits wrapper lines that use the equals form for every
    // value-taking flag — the parser must accept both. Without this,
    // every cron-fired one-shot would die with "unknown option".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{
        "looper",                                   "_exec",
        "--run-id=abc-123",                         "--source-id=daily-backup",
        "--timeout-secs=60",                        "--target-label=local",
        "--",                                       "/bin/sh",
        "-c",                                       "echo hi",
    };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("abc-123", p.run_id.?);
    try testing.expectEqualStrings("daily-backup", p.source_id.?);
    try testing.expectEqual(@as(?u32, 60), p.timeout_secs);
    try testing.expectEqualStrings("local", p.target_label.?);
    try testing.expectEqual(@as(usize, 4), p.positionals.len);
}

test "parseArgv equals form rejects non-numeric --timeout-secs" {
    // Same hard-error behavior as the space form: parser flags bad
    // values rather than letting them flow to the command.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "_exec", "--timeout-secs=nope" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("nope", p.bad_option.?);
}

test "parseArgv full _exec invocation parses cleanly" {
    // Realistic shape of what cron will pass — every _exec flag plus
    // the user's command tokens after `--`. Smoke test for the
    // interaction of these flags with the existing `--` handling.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{
        "looper",         "_exec",
        "--run-id",       "r-42",
        "--source-id",    "oneshot-x",
        "--timeout-secs", "60",
        "--target-label", "local",
        "--once",
        "--",             "/bin/sh", "-c", "echo hi",
    };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqualStrings("r-42", p.run_id.?);
    try testing.expectEqualStrings("oneshot-x", p.source_id.?);
    try testing.expectEqual(@as(?u32, 60), p.timeout_secs);
    try testing.expectEqualStrings("local", p.target_label.?);
    try testing.expect(p.once_flag);
    // Positionals after --: _exec subcommand + the user's shell-cmd tokens.
    try testing.expectEqual(@as(usize, 4), p.positionals.len);
    try testing.expectEqualStrings("_exec", p.positionals[0]);
    try testing.expectEqualStrings("/bin/sh", p.positionals[1]);
    try testing.expectEqualStrings("-c", p.positionals[2]);
    try testing.expectEqualStrings("echo hi", p.positionals[3]);
}

test "parseArgv -j N parses to usize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "-j", "4", "-f", "/tmp/a", "ls" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(?usize, 4), p.jobs);
}

test "parseArgv --jobs=N equals form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "--jobs=8", "-f", "/tmp/a", "ls" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expectEqual(@as(?usize, 8), p.jobs);
}

test "parseArgv -j with non-numeric value sets bad_option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "-j", "abc" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("abc", p.bad_option.?);
}

test "parseArgv --help sets force_help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "--help" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.force_help);
}

test "isValidPrincipal accepts agent-ish names" {
    try testing.expect(isValidPrincipal("agent-a"));
    try testing.expect(isValidPrincipal("deploy.bot"));
    try testing.expect(isValidPrincipal("u_123"));
    try testing.expect(isValidPrincipal("a"));
}

test "isValidPrincipal rejects whitespace, '=', empty, and control bytes" {
    try testing.expect(!isValidPrincipal(""));
    try testing.expect(!isValidPrincipal("deploy agent"));
    try testing.expect(!isValidPrincipal("a\tb"));
    try testing.expect(!isValidPrincipal("a=b"));
    try testing.expect(!isValidPrincipal("a\nb"));
    try testing.expect(!isValidPrincipal("a\x00b"));
}

test "parseArgv rejects --as value containing whitespace" {
    // The marker line is whitespace-tokenized, so a principal with a
    // space would silently truncate on round-trip. The parser must
    // reject at ingress.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--as", "deploy agent", "@daily", "/bin/true" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("deploy agent", p.bad_option.?);
    try testing.expect(p.as == null);
}

test "parseArgv rejects --as=<value with '='>" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--as=foo=bar", "@daily", "/bin/true" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("foo=bar", p.bad_option.?);
}

test "parseArgv rejects --as at end of argv (missing value)" {
    // Without the value-or-fail guard, --as silently swallows nothing
    // and the resulting add writes an un-attributed job. Fail loudly.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--as" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("--as", p.bad_option.?);
}

test "parseArgv rejects --owner at end of argv (missing value)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "ls", "--owner" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("--owner", p.bad_option.?);
}

test "parseArgv rejects --owner value containing whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "ls", "--owner", "team one" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option != null);
    try testing.expectEqualStrings("team one", p.bad_option.?);
    try testing.expect(p.owner == null);
}

test "parseArgv accepts a clean --as principal" {
    // Positive control for the validation tests above.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = newCtx(arena.allocator());
    const argv = [_][]const u8{ "looper", "add", "--as", "agent-a", "@daily", "/bin/true" };
    const p = try parseArgv(arena.allocator(), &argv, &ctx);
    try testing.expect(p.bad_option == null);
    try testing.expectEqualStrings("agent-a", p.as.?);
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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
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
        .new_schedule = null,
        .new_command = null,
        .from_stamp = null,
        .keep = null,
        .check_command = false,
        .capture = false,
        .run_id = null,
        .source_id = null,
        .timeout_secs = null,
        .target_label = null,
        .once_flag = false,
        .status_filter = null,
        .older_than_secs = null,
        .full_output = false,
        .as = null,
        .owner = null,
        .no_wrap = false,
        .jobs = null,
        .force_help = false,
        .bad_option = null,
    };
    const targets = try buildTargets(arena.allocator(), p, "nas\nmedia\n");
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqualStrings("deploy", targets[0].user);
    try testing.expectEqualStrings("deploy", targets[1].user);
}
