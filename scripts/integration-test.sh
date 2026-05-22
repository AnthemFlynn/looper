#!/usr/bin/env bash
# Manual integration test for looper.
#
# Safe to run repeatedly: everything writes to /tmp/looper-itest.* (a file
# target) except the --check-command probes against the local target, which
# run under --dry-run so they never touch your real crontab.
#
# Usage:
#   zig build && ./scripts/integration-test.sh
#
# Each phase prints `==> <name>` then either PASS / FAIL for the assertions
# inside it. Anything that isn't a hard assertion is shown for eyeballing.

set -eu

BIN="${LOOPER_BIN:-./zig-out/bin/looper}"
F="/tmp/looper-itest-$$.crontab"
PASSED=0
FAILED=0

# ── helpers ──────────────────────────────────────────────────────────────────

cleanup() {
  rm -f "$F"
  # Clean per-target backups dir so reruns start fresh.
  local slug_dir="$HOME/.local/state/looper/backups/_tmp_looper-itest-$$.crontab"
  [ -d "$slug_dir" ] && rm -rf "$slug_dir" || true
}
trap cleanup EXIT

hr() { printf '\n==> %s\n' "$1"; }

# pass <label> — record a pass.
pass() { printf '  PASS  %s\n' "$1"; PASSED=$((PASSED+1)); }

# fail <label> [extra] — record a fail.
fail() {
  printf '  FAIL  %s\n' "$1"
  [ "${2:-}" != "" ] && printf '        %s\n' "$2"
  FAILED=$((FAILED+1))
}

# expect_contains <substr> <stdin> <label>
expect_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then pass "$3"
  else fail "$3" "missing: $1"
  fi
}

# expect_absent <substr> <stdin> <label>
expect_absent() {
  if printf '%s' "$2" | grep -qF -- "$1"; then fail "$3" "should be absent: $1"
  else pass "$3"
  fi
}

# expect_status <expected> <actual> <label>
expect_status() {
  if [ "$1" -eq "$2" ]; then pass "$3"
  else fail "$3" "expected exit $1, got $2"
  fi
}

[ -x "$BIN" ] || { echo "looper binary not found at $BIN — run 'zig build' first"; exit 1; }

# ── PHASE 1 — explain (no I/O, pure parser) ──────────────────────────────────
hr "PHASE 1: explain — cron + plain English (no writes)"

out=$("$BIN" --no-color explain "*/15 9-17 * * mon-fri")
echo "$out" | head -3
expect_contains "every 15 minutes" "$out" "cron expression → English"

out=$("$BIN" --no-color explain "every weekday at 8am")
echo "$out" | head -3
expect_contains "0 8 * * 1-5" "$out" "English → cron"

# ── PHASE 2 — add / ls / show on a file target ───────────────────────────────
hr "PHASE 2: add → ls → show round-trip"

"$BIN" --no-color -f "$F" add --id db-backup "0 3 * * *" "/usr/local/bin/backup.sh" >/dev/null
out=$("$BIN" --no-color -f "$F" ls)
echo "$out"
expect_contains "db-backup" "$out" "ls shows the new job"
expect_contains "0 3 * * *" "$out" "schedule rendered"

out=$("$BIN" --no-color -f "$F" show db-backup)
echo "$out" | head -8
expect_contains "next 5" "$out" "show emits next-run list"

# ── PHASE 3 — idempotency by id ──────────────────────────────────────────────
hr "PHASE 3: re-add same id updates in place (no duplicate marker)"

"$BIN" --no-color -f "$F" add --id db-backup "0 4 * * *" "/usr/local/bin/backup.sh --new" >/dev/null
marker_count=$(grep -c '^#looper# id=db-backup' "$F")
expect_status 1 "$marker_count" "exactly one marker line for db-backup"
expect_contains "0 4 * * *" "$(cat "$F")" "schedule updated to 4am"
expect_absent "0 3 * * *" "$(cat "$F")" "old 3am schedule gone"

# ── PHASE 4 — partial edits via `edit` ───────────────────────────────────────
hr "PHASE 4: edit --schedule / --command preserve the other field"

"$BIN" --no-color -f "$F" edit db-backup --schedule "@daily" >/dev/null
expect_contains "@daily" "$(cat "$F")" "edit --schedule applied"
expect_contains "/usr/local/bin/backup.sh --new" "$(cat "$F")" "command preserved"

"$BIN" --no-color -f "$F" edit db-backup --command "/usr/local/bin/backup.sh --final" >/dev/null
expect_contains "/usr/local/bin/backup.sh --final" "$(cat "$F")" "edit --command applied"
expect_contains "@daily" "$(cat "$F")" "schedule preserved"

# ── PHASE 5 — disable / enable preserves definition ──────────────────────────
hr "PHASE 5: disable comments the payload, keeps the definition"

"$BIN" --no-color -f "$F" disable db-backup >/dev/null
expect_contains "enabled=0" "$(cat "$F")" "marker shows enabled=0"
expect_contains "# @daily /usr/local/bin/backup.sh --final" "$(cat "$F")" "payload commented out"

"$BIN" --no-color -f "$F" enable db-backup >/dev/null
expect_contains "enabled=1" "$(cat "$F")" "marker shows enabled=1"

# ── PHASE 6 — foreign jobs ───────────────────────────────────────────────────
hr "PHASE 6: foreign jobs surface as f1/f2 and can be adopted"

# Append a foreign cron line directly (no #looper# marker).
printf '0 7 * * * /opt/legacy/warmup.sh\n' >> "$F"
out=$("$BIN" --no-color -f "$F" ls)
echo "$out"
expect_contains "f1" "$out" "foreign job listed as f1"
expect_contains "unmanaged" "$out" "footnote about unmanaged jobs"

"$BIN" --no-color -f "$F" import >/dev/null
# After import, the foreign line should have a marker.
expect_contains "#looper#" "$(cat "$F")" "import added a marker"
expect_contains "/opt/legacy/warmup.sh" "$(cat "$F")" "foreign command preserved"

# ── PHASE 7 — backups (snapshot + list + dry-run prune) ──────────────────────
hr "PHASE 7: backup snapshot + list + prune --dry-run"

# Sleep 1 to guarantee distinct UTC stamps (resolution is 1s).
"$BIN" --no-color -f "$F" backup >/dev/null
sleep 1
"$BIN" --no-color -f "$F" backup >/dev/null

out=$("$BIN" --no-color -f "$F" backups)
echo "$out"
# Stamp lines are indented and start with `20YYMMDDTHHMMSSZ`.
n=$(printf '%s\n' "$out" | grep -Ec '^[[:space:]]+20[0-9]{6}T[0-9]{6}Z' || true)
[ "$n" -ge 2 ] && pass "at least 2 snapshots listed" || fail "snapshot count" "got $n"

# --keep 0 must be rejected up-front.
set +e
"$BIN" --no-color -f "$F" backups prune --keep 0 2>&1 >/dev/null
rc=$?
set -e
expect_status 2 "$rc" "backups prune --keep 0 rejected"

# --dry-run prune --keep 1 should preview without unlinking.
out=$("$BIN" --no-color -f "$F" --dry-run backups prune --keep 1)
echo "$out"
expect_contains "dry-run" "$out" "prune --dry-run announces no-op"

# ── PHASE 8 — restore --from <substring> ─────────────────────────────────────
hr "PHASE 8: restore --from with substring resolution"

# Grab the first indented timestamp line and strip whitespace.
stamp_full=$("$BIN" --no-color -f "$F" backups \
  | grep -Eo '20[0-9]{6}T[0-9]{6}Z' \
  | head -1)
echo "newest stamp: $stamp_full"
[ -n "$stamp_full" ] || { fail "could not parse newest stamp"; }
# Use just the date prefix as a substring (may match multiple — that's a hard
# error, not a silent first-match).
date_prefix=$(echo "$stamp_full" | cut -c1-8)
set +e
out=$("$BIN" --no-color -f "$F" --dry-run restore --from "$date_prefix" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  expect_contains "matches more than one backup" "$out" "ambiguous substring rejected"
elif [ "$rc" -eq 0 ]; then
  pass "unique substring restored (dry-run preview)"
else
  fail "restore --from rc=$rc" "unexpected"
fi

# Full stamp is always unambiguous.
"$BIN" --no-color -f "$F" --dry-run restore --from "$stamp_full" >/dev/null
pass "restore --from <full-stamp> --dry-run succeeded"

# Positional + --from together must be rejected.
set +e
"$BIN" --no-color -f "$F" restore /some/path --from "$stamp_full" 2>&1 >/dev/null
rc=$?
set -e
expect_status 2 "$rc" "restore rejects positional + --from"

# ── PHASE 9 — --check-command preflight ──────────────────────────────────────
hr "PHASE 9: --check-command preflight (NEW)"

# 9a. File target: probe is always skipped, no warning even for missing bin.
out=$("$BIN" --no-color -f "$F" --dry-run add --check-command --id ghost "@daily" "/zzz/missing/bin" 2>&1)
expect_absent "not found" "$out" "file target: probe skipped, no warning"

# 9b. Local target + missing absolute path under --dry-run: warning emits.
#     dry-run keeps applyMutation from touching your real crontab.
out=$("$BIN" --no-color --dry-run add --check-command --id ghost "@daily" "/zzz/almost/certainly/not/here" 2>&1)
echo "$out" | head -2
expect_contains "not found on local" "$out" "local + missing → yellow ! warning"

# 9c. Local target + existing bin → no warning.
out=$("$BIN" --no-color --dry-run add --check-command --id ok "@daily" "/bin/sh -c 'echo hi'" 2>&1)
expect_absent "not found" "$out" "local + /bin/sh found → silent"

# 9d. Local target + missing bin under --json → warning suppressed.
out=$("$BIN" --dry-run --json add --check-command --id ghost "@daily" "/zzz/missing" 2>&1)
expect_absent "not found" "$out" "--json suppresses the warning"
expect_contains '"dry_run":true' "$out" "JSON document still emitted"

# 9e. Local target + missing bin under --quiet → warning suppressed.
out=$("$BIN" --no-color --dry-run --quiet add --check-command --id ghost "@daily" "/zzz/missing" 2>&1)
expect_absent "not found" "$out" "--quiet suppresses the warning"

# 9f. Without --check-command, no probe runs (no warning either way).
out=$("$BIN" --no-color --dry-run add --id ghost "@daily" "/zzz/missing" 2>&1)
expect_absent "not found" "$out" "no flag → no preflight, no warning"

# 9g. Mis-parseable command (subshell) → probe gives up, no false positive.
out=$("$BIN" --no-color --dry-run add --check-command --id ghost "@daily" "(cd /; ls)" 2>&1)
expect_absent "not found" "$out" "shell construct: probe skipped"

# ── PHASE 10 — bad input is rejected, no writes ──────────────────────────────
hr "PHASE 10: invalid input is rejected without corrupting the file"

before=$(cat "$F")
set +e
"$BIN" --no-color -f "$F" add "this isn't a real schedule" "/bin/x" 2>&1 >/dev/null
rc=$?
set -e
expect_status 1 "$rc" "garbage schedule rejected with exit 1"
after=$(cat "$F")
[ "$before" = "$after" ] && pass "file unchanged after rejection" || fail "file changed despite rejection"

# ── PHASE 11 — doctor preflight ──────────────────────────────────────────────
hr "PHASE 11: doctor preflight against this file target"

out=$("$BIN" --no-color -f "$F" doctor)
echo "$out" | tail -8
expect_contains "environment" "$out" "doctor prints environment section"
expect_contains "backup dir" "$out" "doctor checks backup dir"
expect_contains "crontab readable" "$out" "doctor reads the file target"

# ── PHASE 12 — JSON outputs are valid documents ──────────────────────────────
hr "PHASE 12: --json outputs are parseable"

if command -v python3 >/dev/null 2>&1; then
  out=$("$BIN" -f "$F" --json ls)
  if printf '%s' "$out" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
    pass "ls --json parses as JSON"
  else fail "ls --json parses as JSON" "$out"
  fi

  out=$("$BIN" --json explain "@hourly")
  if printf '%s' "$out" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
    pass "explain --json parses as JSON"
  else fail "explain --json parses as JSON" "$out"
  fi
else
  echo "  (python3 not available, skipping JSON parse checks)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
hr "SUMMARY"
printf '  %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
