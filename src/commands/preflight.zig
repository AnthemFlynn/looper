//! `--check-command` reachability probe + the helpers that drive it.
//!
//! Lives apart from the rest of `commands/` because the surface is small
//! and self-contained: parse a binary out of the command string, decide
//! whether we can ask whether it exists, and (for local + remote)
//! actually ask. Used by `mutate.cmdAdd` and re-used by `doctor`
//! (`hasInPath`).

const std = @import("std");
const posix = @import("../posix.zig");
const target_mod = @import("../crontab/target.zig");

const Target = target_mod.Target;

/// Result of a `--check-command` reachability probe.
/// - `found`: the binary resolves to something executable
/// - `missing`: the probe ran and returned a definite "no"
/// - `skipped`: we couldn't (or shouldn't) ask the question — file
///   targets, shell constructs we can't parse, or a probe that itself
///   crashed. The caller treats `skipped` as silent: no warning, no
///   false-positive "missing" report.
pub const ReachResult = enum { found, missing, skipped };

/// Strip leading `KEY=VAL` env-var assignments from `command` and
/// return the first whitespace-separated token after them. Returns
/// null when nothing checkable remains — the command is empty, starts
/// with a shell construct (`(`, `{`, `$`, a quote, a backtick, a
/// backslash), or the leading run is only env-var assignments.
///
/// Examples (input → output):
///   "/usr/bin/foo arg"           → "/usr/bin/foo"
///   "FOO=bar BAZ=qux /bin/baz"   → "/bin/baz"
///   "rsync src dest"             → "rsync"
///   "(cd /; ls)"                 → null
///   ""                           → null
pub fn extractBinary(command: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, command, " \t");
    while (rest.len > 0) {
        const ws = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const tok = rest[0..ws];
        if (tok.len == 0) return null;
        if (isEnvAssign(tok)) {
            rest = std.mem.trimStart(u8, rest[ws..], " \t");
            continue;
        }
        const c0 = tok[0];
        // Anything we can't statically interpret as a plain binary
        // path: shell groupings, expansions, quoting, command
        // substitution, escapes, or a bare leading `=` (which `isEnvAssign`
        // does not accept — but reaching here means we saw `=foo`,
        // which is neither a name nor an assignment). Better to skip
        // than to mis-report.
        if (c0 == '(' or c0 == '{' or c0 == '$' or c0 == '"' or c0 == '\'' or c0 == '`' or c0 == '\\' or c0 == '=') return null;
        return tok;
    }
    return null;
}

fn isEnvAssign(tok: []const u8) bool {
    // POSIX env-var assignment: `[A-Za-z_][A-Za-z0-9_]*=...`. The `=`
    // must appear after at least one valid name character; bare `=foo`
    // is not an assignment, it's an attempted command.
    if (tok.len < 2) return false;
    if (!(std.ascii.isAlphabetic(tok[0]) or tok[0] == '_')) return false;
    var i: usize = 1;
    while (i < tok.len) : (i += 1) {
        if (tok[i] == '=') return true;
        if (!(std.ascii.isAlphanumeric(tok[i]) or tok[i] == '_')) return false;
    }
    return false;
}

/// Refuse to probe binary names containing shell metacharacters.
/// Anything fancier than `[A-Za-z0-9_.+/-]` almost certainly came from
/// a mis-parsed command, not a real binary name — and we'd otherwise
/// have to shell-quote it for the remote `command -v` invocation.
fn isPlainBinaryName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Real cron commands never start with `-` — that's an option flag
    // someone forgot to pair with a binary. `command -v -- '-c'` would
    // technically be safe (we use `--`), but reporting "command '-c'
    // not found" is misleading noise.
    if (name[0] == '-') return false;
    for (name) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.' or b == '/' or b == '+')) return false;
    }
    return true;
}

/// PATH lookup via libc `access(X_OK)`. Shell-free so the result reflects
/// only file-system reality, not whatever `command -v` decides about
/// aliases/functions in a hypothetical interactive shell. Shared with
/// the doctor's environment-check pass.
pub fn hasInPath(a: std.mem.Allocator, name: []const u8) bool {
    const path_env = posix.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
        const fullz = a.dupeZ(u8, full) catch continue;
        if (posix.c.access(fullz.ptr, posix.c.X_OK) == 0) return true;
    }
    return false;
}

/// Probe whether `binary` is reachable on the target.
/// - local: absolute / relative-with-slash → `access(X_OK)`; bare name → walk PATH
/// - remote: ssh + POSIX `command -v` (one cheap round-trip; same
///   BatchMode/ConnectTimeout constraints as the real crontab read)
/// - file: skipped — no execution context
pub fn commandReachable(a: std.mem.Allocator, t: Target, binary: []const u8) ReachResult {
    if (!isPlainBinaryName(binary)) return .skipped;
    switch (t.kind) {
        .file => return .skipped,
        .local => {
            if (std.mem.indexOfScalar(u8, binary, '/') != null) {
                const z = a.dupeZ(u8, binary) catch return .skipped;
                return if (posix.c.access(z.ptr, posix.c.X_OK) == 0) .found else .missing;
            }
            return if (hasInPath(a, binary)) .found else .missing;
        },
        .remote => {
            // `-u <user>` makes the cron job run as a different user
            // with a different PATH; ssh-ing as our login user would
            // probe the wrong environment and silently return .found
            // when the binary isn't on the crontab owner's PATH. That
            // is exactly the false-confidence outcome this preflight
            // exists to prevent. Skipping is safer than guessing wrong.
            // Delegating via `sudo -u`/`su -l` would work in some
            // configurations but requires extra auth setup we can't
            // assume — and the warning is non-blocking anyway, so a
            // silent skip costs less than a misleading green light.
            if (t.user.len > 0) return .skipped;
            var argv: std.ArrayList([]const u8) = .empty;
            const prefix = target_mod.sshArgvPrefix(a, t.host) catch return .skipped;
            argv.appendSlice(a, prefix) catch return .skipped;
            argv.append(a, "sh") catch return .skipped;
            argv.append(a, "-c") catch return .skipped;
            // `command -v --` accepts both bare names and absolute
            // paths, and exits 0 on hit / 1 on miss. We've already
            // validated `binary` against `isPlainBinaryName`, so
            // single-quoting is safe (no `'` to escape).
            const cmd = std.fmt.allocPrint(a, "command -v -- '{s}' >/dev/null 2>&1", .{binary}) catch return .skipped;
            argv.append(a, cmd) catch return .skipped;
            const r = posix.runCapture(a, argv.items, null) catch return .skipped;
            return switch (r.code) {
                0 => .found,
                1, 127 => .missing,
                else => .skipped,
            };
        },
    }
}

const testing = std.testing;

test "extractBinary returns the first non-assignment token" {
    try testing.expectEqualStrings("/usr/bin/foo", extractBinary("/usr/bin/foo arg1 arg2").?);
    try testing.expectEqualStrings("rsync", extractBinary("rsync -a src dest").?);
    try testing.expectEqualStrings("/bin/sh", extractBinary("  /bin/sh -c 'work'").?);
}

test "extractBinary skips leading KEY=VAL env-var assignments" {
    try testing.expectEqualStrings("/bin/baz", extractBinary("FOO=bar /bin/baz").?);
    try testing.expectEqualStrings("rsync", extractBinary("FOO=1 BAR=2 BAZ=qux rsync src dest").?);
    // Underscore-leading is a valid POSIX env-var name.
    try testing.expectEqualStrings("/bin/foo", extractBinary("_X=1 /bin/foo").?);
}

test "extractBinary gives up on shell constructs" {
    try testing.expect(extractBinary("(cd /; ls)") == null);
    try testing.expect(extractBinary("$VAR_NOT_A_BINARY") == null);
    try testing.expect(extractBinary("`backtick`") == null);
    try testing.expect(extractBinary("\"quoted\"") == null);
    try testing.expect(extractBinary("\\escaped") == null);
    // Bare leading `=` — not a valid env-var assignment, not a binary.
    try testing.expect(extractBinary("=foo") == null);
}

test "extractBinary returns null on empty / whitespace-only" {
    try testing.expect(extractBinary("") == null);
    try testing.expect(extractBinary("   \t  ") == null);
}

test "extractBinary handles only-env-var input gracefully" {
    // No actual binary after the assignments — caller would do nothing.
    try testing.expect(extractBinary("FOO=bar") == null);
}

test "commandReachable on file target is always skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .file, .path = "/tmp/nope" };
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "/bin/sh"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "rsync"));
}

test "commandReachable local: /bin/sh exists, garbage path is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    try testing.expectEqual(ReachResult.found, commandReachable(a, t, "/bin/sh"));
    try testing.expectEqual(ReachResult.missing, commandReachable(a, t, "/zzz/almost/certainly/not/here"));
}

test "commandReachable local: bare name found via PATH walk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    // `sh` is in /bin on every POSIX system the tests would run on.
    try testing.expectEqual(ReachResult.found, commandReachable(a, t, "sh"));
    try testing.expectEqual(ReachResult.missing, commandReachable(a, t, "zzz_definitely_not_a_real_binary_xyz"));
}

test "commandReachable skips shell-metacharacter inputs" {
    // Defence in depth: extractBinary should have filtered these, but
    // commandReachable refuses to probe a name containing anything
    // outside [A-Za-z0-9_.+/-] so we never feed dangerous input to ssh.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .local };
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "$VAR"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "foo;rm -rf"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "foo bar"));
    // Leading `-` is rejected: avoids reporting "command '-c' not
    // found" when the user mis-wrote the command.
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "-c"));
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "--help"));
}

test "commandReachable on remote target with -u user is skipped (avoids false confidence)" {
    // The crontab job runs as `t.user` with that user's PATH; our ssh
    // login user's PATH would give a misleading .found. We refuse to
    // probe rather than mislead — verified without actually shelling
    // out by setting an unreachable host (the user gate must short-
    // circuit before any ssh attempt).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .kind = .remote, .host = "host.invalid", .user = "cronuser" };
    try testing.expectEqual(ReachResult.skipped, commandReachable(a, t, "/bin/sh"));
}

test "hasInPath finds /bin/sh and rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `sh` lives in /bin on every POSIX system the tests would run on,
    // and /bin is always in $PATH for an interactive or CI shell.
    try testing.expect(hasInPath(a, "sh"));
    try testing.expect(!hasInPath(a, "zzz_almost_certainly_not_a_real_binary_xyz"));
}
