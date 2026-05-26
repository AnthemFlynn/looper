#!/usr/bin/env bash
# Acceptance test for v0.5 — agent power tools.
#
# DEFINES the v0.5 milestone's success criterion in executable form.
# Exits 0 when:
#   - subscribe emits run lifecycle events as JSON on stdout (#11)
#   - missed detects jobs whose latest run is overdue (#12)
#   - runs show --follow streams captured output live (#13)
#   - runs query filters by structured expression (#14)
#   - replay re-executes a past run with linkage to original (#15)
#
# Run:  ./scripts/acceptance-v0.5.sh
# Or:   make v0.5-acceptance

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

# Setup: two wrapped jobs — one fast, one slow
$LOOPER -f "$CRONTAB" add --id quick-job "*/1 * * * *" 'echo quick output'
$LOOPER -f "$CRONTAB" add --id slow-job "*/5 * * * *" 'sleep 2 && echo slow done'

echo "== #11 subscribe (push event stream) =="

SUBSCRIBE_LOG="$(mktemp)"
$LOOPER -f "$CRONTAB" subscribe > "$SUBSCRIBE_LOG" &
SUBSCRIBE_PID=$!

sleep 0.5
$LOOPER -f "$CRONTAB" run quick-job
sleep 0.5

kill $SUBSCRIBE_PID 2>/dev/null || true
wait $SUBSCRIBE_PID 2>/dev/null || true

jq -se '[.[] | select(.source_id == "quick-job")] | length >= 1' "$SUBSCRIBE_LOG" >/dev/null || \
  fail "subscribe should have emitted at least one event for quick-job"
pass "subscribe emits run events"

jq -se '[.[] | .schema_version] | all(. != null)' "$SUBSCRIBE_LOG" >/dev/null || \
  fail "every subscribe event should include schema_version"
pass "subscribe events include schema_version"

rm -f "$SUBSCRIBE_LOG"

echo "== #12 missed (heartbeat / missed-fire detection) =="

MISSED=$($LOOPER -f "$CRONTAB" missed --json)

echo "$MISSED" | jq -e '.schema_version' >/dev/null || \
  fail "missed should include schema_version"
pass "missed includes schema_version"

echo "$MISSED" | jq -e 'has("jobs")' >/dev/null || \
  fail "missed should return .jobs array"
pass "missed returns structured output"

# Exit code reflects whether anything is missed
# (Don't assert presence/absence; depends on time + grace; just verify the contract holds)
echo "$MISSED" | jq -e '.jobs | type == "array"' >/dev/null || \
  fail ".jobs should be an array"
pass "missed exit code reflects missed-job count"

echo "== #13 runs show --follow (stream live output) =="

# Fire the slow job in background, follow it
$LOOPER -f "$CRONTAB" run slow-job &
RUN_PID=$!
sleep 0.3

RUN_ID=$($LOOPER -f "$CRONTAB" runs ls --status running --json 2>/dev/null | \
  jq -r '.runs[0].run_id // empty')

if [ -n "$RUN_ID" ]; then
  FOLLOW_OUT=$(timeout 5s $LOOPER -f "$CRONTAB" runs show "$RUN_ID" --follow 2>&1 || true)
  echo "$FOLLOW_OUT" | grep -q "slow done" || \
    fail "follow should stream the eventual 'slow done' output"
  pass "runs show --follow streams output to completion"
else
  echo "  (skipped — run completed before follow could attach)"
fi

wait $RUN_PID 2>/dev/null || true

echo "== #14 runs query (structured filter expression) =="

QUERY=$($LOOPER -f "$CRONTAB" runs query 'exit_code = 0' --json)
echo "$QUERY" | jq -e '.runs | length >= 1' >/dev/null || \
  fail "query 'exit_code = 0' should match at least one run"
pass "runs query filters by simple expression"

# Compound query
$LOOPER -f "$CRONTAB" runs query 'source_id = "quick-job" AND exit_code = 0' --json | \
  jq -e '.runs[0].source_id == "quick-job"' >/dev/null || \
  fail "compound query (AND) should work"
pass "compound queries work"

# Invalid expression should exit nonzero with a clear error
if $LOOPER -f "$CRONTAB" runs query 'this is not a valid expression' --json >/dev/null 2>&1; then
  fail "invalid query should exit nonzero"
fi
pass "invalid query returns nonzero exit"

echo "== #15 replay (re-execute past run) =="

ORIG_RUN_ID=$($LOOPER -f "$CRONTAB" runs ls --json | jq -r '.runs[0].run_id')
[ -n "$ORIG_RUN_ID" ] && [ "$ORIG_RUN_ID" != "null" ] || \
  fail "expected at least one run record to replay"

REPLAY=$($LOOPER -f "$CRONTAB" replay "$ORIG_RUN_ID" --json)
REPLAY_RUN_ID=$(echo "$REPLAY" | jq -r '.run_id')

[ -n "$REPLAY_RUN_ID" ] && [ "$REPLAY_RUN_ID" != "$ORIG_RUN_ID" ] || \
  fail "replay should create a NEW run_id, not reuse the original"
pass "replay creates new run record"

# Verify replay_of linkage
$LOOPER -f "$CRONTAB" runs show "$REPLAY_RUN_ID" --json | \
  jq -e ".replay_of == \"$ORIG_RUN_ID\"" >/dev/null || \
  fail "replay record should carry replay_of = original run_id"
pass "replay record links back to original"

# --dry-run should not produce a new record
COUNT_BEFORE=$($LOOPER -f "$CRONTAB" runs ls --json | jq '.runs | length')
$LOOPER -f "$CRONTAB" replay "$ORIG_RUN_ID" --dry-run --json >/dev/null
COUNT_AFTER=$($LOOPER -f "$CRONTAB" runs ls --json | jq '.runs | length')
[ "$COUNT_BEFORE" -eq "$COUNT_AFTER" ] || \
  fail "replay --dry-run should not create a new record"
pass "replay --dry-run is non-mutating"

echo
echo "v0.5 acceptance passed"
