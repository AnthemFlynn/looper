#!/usr/bin/env bash
# Acceptance test for v0.2 — deployable.
#
# DEFINES the v0.2 milestone's success criterion in executable form.
# Exits 0 when:
#   - Declarative apply with TOML spec converges to spec state (#2)
#   - apply is idempotent — re-running produces no changes (#2)
#   - plan exits nonzero on drift, zero on convergence (#2)
#   - Parallel fan-out via -j N runs without error (#4)
#   - Concurrent edits serialize cleanly with no lost jobs (#8)
#
# Run:  ./scripts/acceptance-v0.2.sh
# Or:   make v0.2-acceptance

set -euo pipefail

LOOPER="${LOOPER_BIN:-zig-out/bin/looper}"
CRONTAB="$(mktemp)"
STATE_DIR="$(mktemp -d)"
SPEC="$(mktemp)"
export XDG_STATE_HOME="$STATE_DIR"

trap 'rm -rf "$CRONTAB" "$STATE_DIR" "$SPEC"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

command -v "$LOOPER" >/dev/null 2>&1 || [ -x "$LOOPER" ] || fail "looper binary not found at $LOOPER"
command -v jq >/dev/null 2>&1 || fail "jq required for acceptance tests"

cat > "$SPEC" <<'EOF'
[[job]]
id = "spec-a"
schedule = "0 3 * * *"
command = "/usr/bin/true"

[[job]]
id = "spec-b"
schedule = "0 4 * * *"
command = "/usr/bin/true"
EOF

echo "== #2 declarative apply =="

$LOOPER -f "$CRONTAB" apply "$SPEC"
$LOOPER -f "$CRONTAB" ls --json | jq -e '.jobs[] | select(.id == "spec-a")' >/dev/null || \
  fail "apply should create spec-a"
$LOOPER -f "$CRONTAB" ls --json | jq -e '.jobs[] | select(.id == "spec-b")' >/dev/null || \
  fail "apply should create spec-b"
pass "apply converges to spec state"

# Idempotency
$LOOPER -f "$CRONTAB" apply "$SPEC"
COUNT=$($LOOPER -f "$CRONTAB" ls --json | \
  jq '[.jobs[] | select(.id == "spec-a" or .id == "spec-b")] | length')
[ "$COUNT" -eq 2 ] || fail "apply should be idempotent; got $COUNT jobs (expected 2)"
pass "apply is idempotent"

# plan exits 0 when no diff
$LOOPER -f "$CRONTAB" plan "$SPEC" >/dev/null || fail "plan should exit 0 on convergence"
pass "plan exits 0 on no diff"

# plan exits nonzero on drift
cat >> "$SPEC" <<'EOF'

[[job]]
id = "spec-c"
schedule = "0 5 * * *"
command = "/usr/bin/true"
EOF
if $LOOPER -f "$CRONTAB" plan "$SPEC" >/dev/null 2>&1; then
  fail "plan should exit nonzero when spec drifts from state"
fi
pass "plan exits nonzero on drift"

echo "== #4 parallel fan-out =="

CT1="$(mktemp)"
CT2="$(mktemp)"
CT3="$(mktemp)"
trap 'rm -rf "$CRONTAB" "$STATE_DIR" "$SPEC" "$CT1" "$CT2" "$CT3"' EXIT

# Both -j 1 (sequential) and -j N (parallel) should produce equivalent output
$LOOPER -f "$CT1" -f "$CT2" -f "$CT3" -j 1 ls --json >/dev/null || \
  fail "-j 1 sequential fan-out should work"
pass "sequential fan-out (-j 1)"

$LOOPER -f "$CT1" -f "$CT2" -f "$CT3" -j 4 ls --json >/dev/null || \
  fail "-j 4 parallel fan-out should work"
pass "parallel fan-out (-j 4)"

# Output ordering should be deterministic (target-list order) in default buffered mode
ORDER_A=$($LOOPER -f "$CT1" -f "$CT2" -f "$CT3" -j 4 ls --json | jq -r '.target')
ORDER_B=$($LOOPER -f "$CT1" -f "$CT2" -f "$CT3" -j 4 ls --json | jq -r '.target')
[ "$ORDER_A" = "$ORDER_B" ] || fail "parallel output should be deterministically ordered"
pass "parallel output order is deterministic"

echo "== #8 cross-caller locking =="

SHARED_CT="$(mktemp)"
trap 'rm -rf "$CRONTAB" "$STATE_DIR" "$SPEC" "$CT1" "$CT2" "$CT3" "$SHARED_CT"' EXIT

# Spawn two concurrent adds against the same target
$LOOPER -f "$SHARED_CT" add --id concurrent-a "0 1 * * *" 'true' &
PID_A=$!
$LOOPER -f "$SHARED_CT" add --id concurrent-b "0 2 * * *" 'true' &
PID_B=$!

wait $PID_A || fail "concurrent add A failed"
wait $PID_B || fail "concurrent add B failed"

# Both jobs should exist after both writes — no lost write
$LOOPER -f "$SHARED_CT" ls --json | \
  jq -e '[.jobs[] | select(.id == "concurrent-a" or .id == "concurrent-b")] | length == 2' >/dev/null || \
  fail "concurrent adds should both succeed; one was lost (lock not held during read-modify-write)"
pass "concurrent adds serialize without job loss"

echo
echo "v0.2 acceptance passed"
