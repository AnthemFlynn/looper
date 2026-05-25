#!/usr/bin/env bash
# Acceptance test for v0.6 — ergonomics.
#
# DEFINES the v0.6 milestone's success criterion in executable form.
# Exits 0 when:
#   - edit -e accepts a valid scripted EDITOR edit and rejects invalid (#21)
#   - tui starts in smoke-test mode without crashing (#22)
#   - completions emit parseable scripts for bash/zsh/fish; man page exists (#23)
#   - export --format spec round-trips with apply (#24)
#   - iCal export produces a well-formed VCALENDAR (#25)
#
# Run:  ./scripts/acceptance-v0.6.sh
# Or:   make v0.6-acceptance

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

# Seed
$LOOPER -f "$CRONTAB" add --id seed-a "0 1 * * *" 'true'
$LOOPER -f "$CRONTAB" add --id seed-b "0 2 * * *" 'true'

echo "== #21 edit -e (full-set editor flow) =="

EDITOR_OK="$(mktemp)"
cat > "$EDITOR_OK" <<'EOF'
#!/bin/sh
# Benign edit: append a comment line that won't break parsing.
echo "# edited by acceptance test" >> "$1"
EOF
chmod +x "$EDITOR_OK"

EDITOR="$EDITOR_OK" $LOOPER -f "$CRONTAB" edit -e -y || \
  fail "edit -e should accept a valid scripted edit"
grep -q "edited by acceptance test" "$CRONTAB" || \
  fail "edit -e should persist the editor's changes"
pass "edit -e accepts valid edits"

EDITOR_BAD="$(mktemp)"
cat > "$EDITOR_BAD" <<'EOF'
#!/bin/sh
# Invalid: insert a line that's neither valid cron nor a comment.
echo "this is not a valid cron line at all" >> "$1"
EOF
chmod +x "$EDITOR_BAD"

if EDITOR="$EDITOR_BAD" $LOOPER -f "$CRONTAB" edit -e -y 2>/dev/null; then
  fail "edit -e should reject content with invalid cron lines"
fi
pass "edit -e rejects invalid content"

rm -f "$EDITOR_OK" "$EDITOR_BAD"

echo "== #22 tui (smoke test) =="

# TUI should support a non-interactive smoke-test mode for CI / acceptance
if $LOOPER -f "$CRONTAB" tui --smoke-test >/dev/null 2>&1; then
  pass "tui starts and exits cleanly in --smoke-test mode"
else
  fail "tui should support --smoke-test (initialize, render one frame, exit 0)"
fi

echo "== #23 completions + man page =="

# Bash completion script should be syntactically valid
$LOOPER completions bash | bash -n || \
  fail "bash completion script should parse cleanly under 'bash -n'"
pass "bash completion is well-formed"

# Zsh completion should look like a zsh completion script
ZSH_OUT=$($LOOPER completions zsh)
echo "$ZSH_OUT" | head -1 | grep -qE '^#compdef|^# zsh' || \
  echo "$ZSH_OUT" | grep -q '_looper' || \
  fail "zsh completion should start with #compdef or contain _looper function"
pass "zsh completion looks like a zsh completion script"

# Fish completion should use 'complete -c looper'
$LOOPER completions fish | grep -q 'complete -c looper' || \
  fail "fish completion should contain 'complete -c looper'"
pass "fish completion uses 'complete -c looper'"

# Man page should be installed in a standard location
MAN_FOUND=""
LOOPER_DIR="$(dirname "$(readlink -f "$LOOPER" 2>/dev/null || realpath "$LOOPER")")"
for CANDIDATE in \
  "$LOOPER_DIR/../share/man/man1/looper.1" \
  /usr/local/share/man/man1/looper.1 \
  /usr/share/man/man1/looper.1 \
  "$HOME/.local/share/man/man1/looper.1"
do
  if [ -f "$CANDIDATE" ]; then
    MAN_FOUND="$CANDIDATE"
    break
  fi
done
[ -n "$MAN_FOUND" ] || fail "looper.1 man page should be installed in a standard location"
pass "man page installed at $MAN_FOUND"

echo "== #24 export --format spec (bidirectional with apply) =="

SPEC_OUT="$(mktemp)"
FRESH_CT="$(mktemp)"
trap 'rm -rf "$CRONTAB" "$STATE_DIR" "$SPEC_OUT" "$FRESH_CT"' EXIT

$LOOPER -f "$CRONTAB" export --format spec > "$SPEC_OUT"
grep -q '\[\[job\]\]' "$SPEC_OUT" || \
  fail "exported spec should contain [[job]] entries"
pass "export emits TOML spec format"

# Round-trip: apply the exported spec to a fresh crontab, ids should match
$LOOPER -f "$FRESH_CT" apply "$SPEC_OUT"
ORIG_IDS=$($LOOPER -f "$CRONTAB" ls --json | jq -r '[.jobs[].id] | sort | @csv')
FRESH_IDS=$($LOOPER -f "$FRESH_CT" ls --json | jq -r '[.jobs[].id] | sort | @csv')
[ "$ORIG_IDS" = "$FRESH_IDS" ] || \
  fail "export → apply should round-trip job ids: orig=$ORIG_IDS fresh=$FRESH_IDS"
pass "export → apply round-trip preserves managed set"

echo "== #25 iCal export =="

ICAL=$($LOOPER -f "$CRONTAB" agenda --format ical --horizon 7d)
echo "$ICAL" | grep -qE '^BEGIN:VCALENDAR' || \
  fail "iCal output should start with BEGIN:VCALENDAR"
echo "$ICAL" | grep -qE '^END:VCALENDAR' || \
  fail "iCal output should end with END:VCALENDAR"
echo "$ICAL" | grep -qE '^BEGIN:VEVENT' || \
  fail "iCal output should contain at least one VEVENT block"
echo "$ICAL" | grep -qE '^UID:' || \
  fail "VEVENT blocks should have UID lines (for stable calendar-app dedup)"
echo "$ICAL" | grep -qE '^DTSTART:' || \
  fail "VEVENT blocks should have DTSTART lines"
pass "iCal export is well-formed VCALENDAR 2.0"

echo
echo "v0.6 acceptance passed"
