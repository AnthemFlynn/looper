#!/usr/bin/env bash
# Acceptance test for v0.1 — agent loop closes.
#
# DEFINES the v0.1 milestone's success criterion in executable form.
# Will fail until issues #1, #3, #5, #6 are implemented; that's the point.
# When this exits 0 against a real binary, v0.1 is shippable.
#
# Exits 0 when an agent can:
#   - Install a recurring task that wraps by default (#3)
#   - Identify itself via --as / LOOPER_AS and filter by owner (#6)
#   - Read structured JSON with schema_version (#5)
#   - See history of past runs via the history command (#1)
#
# Run:  ./scripts/acceptance-v0.1.sh
# Or:   make v0.1-acceptance

set -euo pipefail

LOOPER="${LOOPER_BIN:-zig-out/bin/looper}"
CRONTAB="$(mktemp)"
STATE_DIR="$(mktemp -d)"
export XDG_STATE_HOME="$STATE_DIR"

trap 'rm -rf "$CRONTAB" "$STATE_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

command -v "$LOOPER" >/dev/null 2>&1 || [ -x "$LOOPER" ] || fail "looper binary not found at $LOOPER"
command -v jq >/dev/null 2>&1 || fail "jq required for acceptance tests"

echo "== #3 wrap-by-default =="

$LOOPER -f "$CRONTAB" add --as agent-a --id hello "*/1 * * * *" 'echo hello'
grep -q '_exec' "$CRONTAB" || fail "add should produce a wrapped cron line containing _exec"
pass "add produces wrapped line by default"

$LOOPER -f "$CRONTAB" add --as agent-a --id bare --no-wrap "*/1 * * * *" 'echo bare'
grep '#looper# id=bare' "$CRONTAB" -A 1 | grep -qv '_exec' || \
  fail "--no-wrap should produce a bare cron line"
pass "--no-wrap escape hatch works"

echo "== #5 JSON-first output =="

# Piped (non-TTY) stdout defaults to JSON
JSON_OUTPUT="$($LOOPER -f "$CRONTAB" ls)"
echo "$JSON_OUTPUT" | jq -e '.schema_version' >/dev/null || \
  fail "non-tty ls should default to JSON with schema_version"
pass "non-tty ls defaults to JSON"

echo "$JSON_OUTPUT" | jq -e '.jobs[] | select(.id == "hello")' >/dev/null || \
  fail "ls JSON should contain the hello job"
pass "ls JSON contains added jobs"

# Explicit --json works regardless of TTY
$LOOPER -f "$CRONTAB" ls --json | jq -e '.schema_version' >/dev/null || \
  fail "--json explicit flag should produce schema_version"
pass "--json explicit flag works"

echo "== #6 provenance + ownership filtering =="

$LOOPER -f "$CRONTAB" ls --owner agent-a --json | \
  jq -e '.jobs | length >= 2' >/dev/null || \
  fail "ls --owner agent-a should find both jobs"
pass "ls --owner filter includes owner's jobs"

$LOOPER -f "$CRONTAB" ls --owner nobody --json | \
  jq -e '.jobs | length == 0' >/dev/null || \
  fail "ls --owner nobody should be empty"
pass "ls --owner filter excludes non-owners"

# Show exposes provenance fields
$LOOPER -f "$CRONTAB" show hello --json | \
  jq -e '.created_by == "agent-a"' >/dev/null || \
  fail "show should expose created_by field"
pass "show exposes created_by"

# LOOPER_AS env var as alternative to --as
LOOPER_AS=env-agent $LOOPER -f "$CRONTAB" add --id from-env "0 0 * * *" 'true'
$LOOPER -f "$CRONTAB" show from-env --json | \
  jq -e '.created_by == "env-agent"' >/dev/null || \
  fail "LOOPER_AS env should set created_by"
pass "LOOPER_AS env var works"

echo "== #1 history (the read side of the feedback loop) =="

# Fire one run manually to generate a captured record
$LOOPER -f "$CRONTAB" run hello

# history command should show that run
$LOOPER -f "$CRONTAB" history hello --json | \
  jq -e '.runs[0].exit_code == 0' >/dev/null || \
  fail "history should show the just-fired run with exit_code=0"
pass "history shows past runs"

# last should resolve to the most recent
$LOOPER -f "$CRONTAB" last hello --json | \
  jq -e '.exit_code == 0' >/dev/null || \
  fail "last should resolve to most recent run"
pass "last resolves to most recent run"

# The full v0.1 agent loop: install → run → read
RUN_ID=$($LOOPER -f "$CRONTAB" runs ls --owner agent-a --json | jq -r '.runs[0].run_id')
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || fail "runs ls --owner should find captured run"

$LOOPER -f "$CRONTAB" runs show "$RUN_ID" --json | \
  jq -e '.captured.stdout' >/dev/null || \
  fail "runs show should expose captured stdout"
pass "captured stdout readable end-to-end"

echo
echo "v0.1 acceptance passed"
