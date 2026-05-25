#!/usr/bin/env bash
# Acceptance test for v0.3 — observability.
#
# DEFINES the v0.3 milestone's success criterion in executable form.
# Exits 0 when:
#   - agenda lists chronological next fires (#10)
#   - diff detects drift between managed set and actual crontab (#10)
#   - verify runs end-to-end checks per defined contract (#7)
#
# Run:  ./scripts/acceptance-v0.3.sh
# Or:   make v0.3-acceptance

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

# Seed crontab with jobs that have distinct next-run times
$LOOPER -f "$CRONTAB" add --id "next-soon" "*/1 * * * *" '/usr/bin/true'
$LOOPER -f "$CRONTAB" add --id "next-later" "0 12 * * *" '/usr/bin/true'

echo "== #10 agenda =="

AGENDA=$($LOOPER -f "$CRONTAB" agenda --json)
echo "$AGENDA" | jq -e '.schema_version' >/dev/null || \
  fail "agenda JSON should include schema_version"
pass "agenda includes schema_version"

echo "$AGENDA" | jq -e '.events | length >= 2' >/dev/null || \
  fail "agenda should list events for both jobs"
pass "agenda lists scheduled events"

# Sorted chronologically by next-fire unix time
echo "$AGENDA" | jq -e '
  .events
  | [.[].next_unix]
  | . as $arr
  | $arr == ($arr | sort)
' >/dev/null || fail "agenda events should be sorted by next_unix ascending"
pass "agenda is chronologically sorted"

echo "== #10 diff (drift detection) =="

# Clean state: looper's view matches the crontab → diff exits 0
$LOOPER -f "$CRONTAB" diff || fail "diff on clean state should exit 0"
pass "diff exits 0 on clean state"

# Introduce drift by editing the crontab outside looper
echo "" >> "$CRONTAB"
echo "0 23 * * * /opt/some-foreign-job" >> "$CRONTAB"

# diff should now detect drift and exit nonzero
if $LOOPER -f "$CRONTAB" diff >/dev/null 2>&1; then
  fail "diff should exit nonzero when foreign lines exist"
fi
pass "diff exits nonzero on drift"

DIFF_JSON=$($LOOPER -f "$CRONTAB" diff --json 2>/dev/null || true)
echo "$DIFF_JSON" | jq -e '.foreign | length >= 1' >/dev/null || \
  fail "diff --json should report at least one foreign line"
pass "diff JSON identifies drift category"

echo "== #7 verify (end-to-end smoke test) =="

VERIFY=$($LOOPER -f "$CRONTAB" verify next-soon --json)

echo "$VERIFY" | jq -e '.schema_version' >/dev/null || \
  fail "verify JSON should include schema_version"
pass "verify includes schema_version"

echo "$VERIFY" | jq -e '.checks | length >= 3' >/dev/null || \
  fail "verify should run at least 3 checks (schedule, daemon, command)"
pass "verify runs multiple checks"

echo "$VERIFY" | jq -e '.checks[] | has("name") and has("ok")' >/dev/null || \
  fail "each check should have .name and .ok fields"
pass "each check has structured status"

echo "$VERIFY" | jq -e 'has("ok")' >/dev/null || \
  fail "verify should produce overall .ok signal"
pass "verify produces overall ok signal"

# Verify works on every managed job in one call
$LOOPER -f "$CRONTAB" verify --json | jq -e '.jobs | length >= 2' >/dev/null || \
  fail "verify with no id should check all jobs"
pass "verify --all-jobs mode works"

echo
echo "v0.3 acceptance passed"
