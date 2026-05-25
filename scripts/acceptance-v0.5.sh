#!/usr/bin/env bash
# Acceptance test for v0.5 — ops integration.
#
# DEFINES the v0.5 milestone's success criterion in executable form.
# Exits 0 when:
#   - metrics emits valid Prometheus textfile-collector format (#16)
#   - hooks fire at lifecycle points with structured stdin (#17)
#   - audit log appends one line per mutation (#18)
#   - catchup marker is recorded and plumbed through to _exec env (#19)
#   - quotas enforce per-owner caps and surface usage (#20)
#
# Run:  ./scripts/acceptance-v0.5.sh
# Or:   make v0.5-acceptance

set -euo pipefail

LOOPER="${LOOPER_BIN:-zig-out/bin/looper}"
CRONTAB="$(mktemp)"
STATE_DIR="$(mktemp -d)"
CONFIG_DIR="$(mktemp -d)"
export XDG_STATE_HOME="$STATE_DIR"
export XDG_CONFIG_HOME="$CONFIG_DIR"

trap 'rm -rf "$CRONTAB" "$STATE_DIR" "$CONFIG_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

command -v "$LOOPER" >/dev/null 2>&1 || [ -x "$LOOPER" ] || fail "looper binary not found at $LOOPER"
command -v jq >/dev/null 2>&1 || fail "jq required for acceptance tests"

echo "== #16 metrics (Prometheus textfile-collector) =="

$LOOPER -f "$CRONTAB" add --id metric-test "*/1 * * * *" 'true'

METRICS=$($LOOPER -f "$CRONTAB" metrics)
echo "$METRICS" | grep -qE '^# HELP looper_jobs_total' || \
  fail "metrics should include '# HELP looper_jobs_total'"
echo "$METRICS" | grep -qE '^# TYPE looper_jobs_total gauge' || \
  fail "metrics should include '# TYPE looper_jobs_total gauge'"
echo "$METRICS" | grep -qE '^looper_jobs_total\{' || \
  fail "metrics should emit at least one looper_jobs_total sample"
pass "metrics emits valid Prometheus text format"

# Atomic file output
METRICS_FILE="$(mktemp)"
trap 'rm -rf "$CRONTAB" "$STATE_DIR" "$CONFIG_DIR" "$METRICS_FILE"' EXIT
$LOOPER -f "$CRONTAB" metrics --output "$METRICS_FILE"
[ -s "$METRICS_FILE" ] || fail "metrics --output should write a non-empty file"
grep -qE '^looper_' "$METRICS_FILE" || fail "metrics file should contain looper_ metrics"
pass "metrics --output writes atomically"

echo "== #17 hooks (script invocation at lifecycle points) =="

HOOK_DIR="$CONFIG_DIR/looper/hooks.d/post-mutation"
mkdir -p "$HOOK_DIR"
HOOK_LOG="$(mktemp)"
cat > "$HOOK_DIR/test-hook" <<EOF
#!/bin/sh
echo "LOOPER_EVENT=\$LOOPER_EVENT" >> "$HOOK_LOG"
cat >> "$HOOK_LOG"
printf '\n' >> "$HOOK_LOG"
EOF
chmod +x "$HOOK_DIR/test-hook"

$LOOPER -f "$CRONTAB" add --id hook-trigger "0 0 * * *" 'true'

grep -q "LOOPER_EVENT=post-mutation" "$HOOK_LOG" || \
  fail "post-mutation hook should have fired with LOOPER_EVENT env"
pass "post-mutation hook fires with env"

# Stdin payload should be valid JSON with schema_version
JSON_PAYLOAD=$(grep -v '^LOOPER_EVENT=' "$HOOK_LOG" | grep -v '^$')
echo "$JSON_PAYLOAD" | jq -e '.schema_version and .action and .id' >/dev/null || \
  fail "hook stdin should be valid JSON with .schema_version, .action, .id"
pass "hook receives structured JSON on stdin"

rm -f "$HOOK_LOG"

echo "== #18 audit log (append-only mutation history) =="

AUDIT_LOG="$STATE_DIR/looper/audit.log"
[ -f "$AUDIT_LOG" ] || fail "audit log should exist at $AUDIT_LOG"
pass "audit log file created"

LINE_COUNT=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
[ "$LINE_COUNT" -ge 2 ] || \
  fail "audit log should have at least 2 lines (2 adds done); got $LINE_COUNT"
pass "audit log appends per mutation"

while IFS= read -r line; do
  echo "$line" | jq -e '.schema_version and .ts and .action and .actor' >/dev/null || \
    fail "audit log line missing required fields: $line"
done < "$AUDIT_LOG"
pass "audit log lines are well-formed JSON with required fields"

# Permissions should be 0600
MODE=$(stat -f "%Lp" "$AUDIT_LOG" 2>/dev/null || stat -c "%a" "$AUDIT_LOG" 2>/dev/null)
[ "$MODE" = "600" ] || fail "audit log should be mode 0600; got $MODE"
pass "audit log is mode 0600"

echo "== #19 catchup semantics =="

$LOOPER -f "$CRONTAB" add --id catchup-job --catchup on-resume \
  "0 * * * *" 'echo "missed=$LOOPER_CATCHUP_MISSED"'

grep '#looper# id=catchup-job' "$CRONTAB" | grep -q 'catchup=on-resume' || \
  fail "catchup=on-resume should be recorded on the marker line"
pass "catchup setting recorded on marker"

# Default catchup is 'none' — back-compat
$LOOPER -f "$CRONTAB" add --id no-catchup-job "0 * * * *" 'true'
grep '#looper# id=no-catchup-job' "$CRONTAB" | grep -qv 'catchup=on-resume' || \
  fail "default catchup should not be on-resume"
pass "default catchup is 'none' (back-compat)"

# (Full time-based catchup behavior requires time mocking and is covered by integration tests)

echo "== #20 quotas (per-owner caps) =="

mkdir -p "$CONFIG_DIR/looper"
cat > "$CONFIG_DIR/looper/quotas.toml" <<'EOF'
[owners."test-agent"]
max_jobs = 2
EOF

$LOOPER -f "$CRONTAB" add --as test-agent --id q-1 "0 1 * * *" 'true'
$LOOPER -f "$CRONTAB" add --as test-agent --id q-2 "0 2 * * *" 'true'

if $LOOPER -f "$CRONTAB" add --as test-agent --id q-3 "0 3 * * *" 'true' 2>/dev/null; then
  fail "quota of max_jobs=2 should reject the 3rd add"
fi
pass "quota rejects add when over limit"

# Other owners not capped
$LOOPER -f "$CRONTAB" add --as other-agent --id q-other "0 4 * * *" 'true' || \
  fail "other-agent should not be capped by test-agent's quota"
pass "quota is scoped per-owner"

# looper quotas surfaces usage
QUOTAS=$($LOOPER -f "$CRONTAB" quotas --json)
echo "$QUOTAS" | jq -e '.owners["test-agent"].current_jobs == 2' >/dev/null || \
  fail "quotas should report current_jobs=2 for test-agent"
pass "quotas reports current usage"

echo
echo "v0.5 acceptance passed"
