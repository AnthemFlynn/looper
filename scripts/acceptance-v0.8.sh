#!/usr/bin/env bash
# Acceptance test for v0.8 — mcp (RFC).
#
# v0.8 is an RFC milestone, not an implementation milestone. Acceptance is:
#   - docs/rfc/mcp.md exists with the resolved design
#   - The RFC document resolves the open questions from issue #9
#     (transport, auth model, daemon vs per-call, in-tree vs separate binary,
#      dep policy / libc-only impact)
#   - Issue #9 is closed on GitHub (RFC accepted)
#   - Implementation issues for MCP are filed under a follow-on milestone
#
# When MCP implementation begins, a new milestone + acceptance script
# (acceptance-v0.9.sh or similar) will replace this one for the
# implementation acceptance.
#
# Run:  ./scripts/acceptance-v0.8.sh
# Or:   make v0.8-acceptance

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RFC="$REPO_ROOT/docs/rfc/mcp.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

echo "== #9 mcp RFC =="

[ -f "$RFC" ] || fail "docs/rfc/mcp.md should exist with the resolved MCP design"
pass "MCP RFC document exists at docs/rfc/mcp.md"

# The RFC should resolve each open question from issue #9
QUESTIONS=(
  "transport"
  "auth"
  "daemon"
  "tree"
  "dep"
)
MISSING=()
for q in "${QUESTIONS[@]}"; do
  grep -qiE "$q" "$RFC" || MISSING+=("$q")
done
if [ "${#MISSING[@]}" -ne 0 ]; then
  fail "RFC missing discussion of: ${MISSING[*]}"
fi
pass "RFC discusses all open design questions"

# Should declare a concrete decision per question
grep -qiE "^## (Decision|Resolution|Design)|^### Decision" "$RFC" || \
  fail "RFC should have a Decision / Resolution / Design section"
pass "RFC has a resolved-decision section"

# Issue #9 should be closed
if command -v gh >/dev/null 2>&1; then
  STATE=$(gh issue view 9 -R AnthemFlynn/looper --json state -q .state 2>/dev/null || echo "UNKNOWN")
  [ "$STATE" = "CLOSED" ] || \
    fail "issue #9 should be CLOSED when v0.8 RFC is accepted (current state: $STATE)"
  pass "RFC issue #9 is closed"

  # Implementation issues should exist under a follow-on milestone
  IMPL_COUNT=$(gh issue list -R AnthemFlynn/looper --search "mcp in:title" \
    --state open --json number --jq 'length' 2>/dev/null || echo 0)
  [ "$IMPL_COUNT" -ge 1 ] || \
    fail "MCP implementation issues should be filed once the RFC is accepted"
  pass "MCP implementation issues filed ($IMPL_COUNT open)"
else
  echo "  (gh CLI not available — skipping GitHub-side checks)"
fi

echo
echo "v0.8 acceptance passed"
