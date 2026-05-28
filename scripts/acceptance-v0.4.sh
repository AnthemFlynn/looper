#!/usr/bin/env bash
# Acceptance test for v0.4 — remote deployment.
#
# DEFINES the v0.4 milestone's success criterion in executable form.
# Exits 0 when:
#   - push deploys a single file with provenance, unpush removes it (#27)
#   - push --bundle deploys a directory tree in one ssh round trip (#28)
#   - add --inline-script embeds a small script in the cron line (#29)
#   - apply with [[file]] + [[job]] blocks deploys atomically with rollback (#30)
#   - credential-passthrough contract is documented in CLAUDE.md (#31)
#
# Run:  ./scripts/acceptance-v0.4.sh
# Or:   make v0.4-acceptance
#
# This script is forward-looking — it will fail until v0.4 ships. The shape
# locks in what "shippable for v0.4" means before implementation begins.

set -euo pipefail

LOOPER="${LOOPER_BIN:-zig-out/bin/looper}"
STATE_DIR="$(mktemp -d)"
CRONTAB="$(mktemp)"
# A "remote" simulated as a writable local dir. File-target ssh is the same
# code path on the looper side; using a temp dir keeps the acceptance test
# self-contained (no actual ssh required for CI). The push/unpush primitives
# detect `file:` targets and fall through to local cp semantics so the test
# exercises the bookkeeping path without needing a real remote.
SIM_REMOTE="$(mktemp -d)"
export XDG_STATE_HOME="$STATE_DIR"

trap 'rm -rf "$STATE_DIR" "$CRONTAB" "$SIM_REMOTE"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

command -v "$LOOPER" >/dev/null 2>&1 || [ -x "$LOOPER" ] || fail "looper binary not found at $LOOPER"
command -v jq >/dev/null 2>&1 || fail "jq required for acceptance tests"

echo "== #27 push / unpush (single-file with provenance) =="

# Write a tiny "script" the agent wants to deploy
SCRIPT_SRC="$(mktemp)"
cat > "$SCRIPT_SRC" <<'EOF'
#!/usr/bin/env python3
print("hello from pushed script")
EOF

REMOTE_PATH="$SIM_REMOTE/agent-scripts/scrape.py"

# Push records ownership when --as is provided
$LOOPER --as agent-a push "$SCRIPT_SRC" "$REMOTE_PATH" || \
  fail "push should succeed against a writable remote path"
[ -f "$REMOTE_PATH" ] || fail "push should place the file at the target path"
pass "push lands the file"

# Mode preserved from source (or --mode override applied)
SRC_MODE=$(stat -f "%Lp" "$SCRIPT_SRC" 2>/dev/null || stat -c "%a" "$SCRIPT_SRC" 2>/dev/null)
DST_MODE=$(stat -f "%Lp" "$REMOTE_PATH" 2>/dev/null || stat -c "%a" "$REMOTE_PATH" 2>/dev/null)
[ "$SRC_MODE" = "$DST_MODE" ] || fail "push should preserve mode; src=$SRC_MODE dst=$DST_MODE"
pass "push preserves file mode"

# Push record visible with ownership round-trip
$LOOPER pushes ls --json | jq -e \
  ".pushes[] | select(.remote == \"$REMOTE_PATH\") | .created_by == \"agent-a\"" >/dev/null || \
  fail "pushes ls --json should surface created_by=agent-a"
pass "push record includes provenance"

# Owner filter
$LOOPER pushes ls --owner agent-a --json | jq -e '.pushes | length >= 1' >/dev/null || \
  fail "pushes ls --owner agent-a should include the push"
$LOOPER pushes ls --owner agent-other --json | jq -e '.pushes | length == 0' >/dev/null || \
  fail "pushes ls --owner agent-other should NOT include agent-a's push"
pass "pushes ls --owner filters correctly"

# unpush removes the file and the record
$LOOPER unpush "$REMOTE_PATH" || fail "unpush should succeed"
[ ! -f "$REMOTE_PATH" ] || fail "unpush should remove the file"
$LOOPER pushes ls --json | jq -e \
  "[.pushes[] | select(.remote == \"$REMOTE_PATH\")] | length == 0" >/dev/null || \
  fail "unpush should remove the push record"
pass "unpush removes file + record"

rm -f "$SCRIPT_SRC"

echo "== #28 push --bundle (multi-file via tar over one ssh) =="

BUNDLE_SRC="$(mktemp -d)"
cat > "$BUNDLE_SRC/main.py" <<'EOF'
from helpers import greet
print(greet())
EOF
cat > "$BUNDLE_SRC/helpers.py" <<'EOF'
def greet(): return "hi"
EOF
mkdir -p "$BUNDLE_SRC/data"
echo '{"version": 1}' > "$BUNDLE_SRC/data/config.json"

BUNDLE_DST="$SIM_REMOTE/bundle-target"

$LOOPER --as agent-a push --bundle "$BUNDLE_SRC/" "$BUNDLE_DST/" || \
  fail "push --bundle should succeed"

for f in main.py helpers.py data/config.json; do
  [ -f "$BUNDLE_DST/$f" ] || fail "bundle should have deployed $f"
done
pass "bundle deploys every file"

# Bundle is one push record (not N records, one per file)
$LOOPER pushes ls --json | jq -e \
  "[.pushes[] | select(.bundle == true and .remote == \"$BUNDLE_DST/\")] | length == 1" >/dev/null || \
  fail "bundle should be one push record with bundle=true"
pass "bundle is single push record"

# Recursive symlinks should be rejected (would leak local FS shape)
ln -s "$BUNDLE_SRC" "$BUNDLE_SRC/self-loop"
if $LOOPER push --bundle "$BUNDLE_SRC/" "$SIM_REMOTE/should-fail/" 2>/dev/null; then
  fail "bundle with recursive symlink should be rejected"
fi
pass "bundle rejects recursive symlinks"
rm -rf "$BUNDLE_SRC" "$BUNDLE_DST"

echo "== #29 add --inline-script (small scripts embedded in cron line) =="

INLINE_SRC="$(mktemp --suffix=.py)"
cat > "$INLINE_SRC" <<'EOF'
#!/usr/bin/env python3
import sys
print("inline ok")
sys.exit(0)
EOF

$LOOPER -f "$CRONTAB" add --id daily-inline --inline-script "$INLINE_SRC" "0 8 * * *" || \
  fail "add --inline-script should accept a script with a shebang"
pass "add --inline-script accepts shebanged script"

# The encoded payload should reference python3 (from shebang detection)
grep "#looper# id=daily-inline" "$CRONTAB" >/dev/null || fail "marker line should be present"
grep -E "python3 -c|base64" "$CRONTAB" >/dev/null || \
  fail "inline-script cron line should invoke python3 -c with a decode step"
pass "inline cron line uses interpreter from shebang"

# ls --json should surface the ORIGINAL script content (decoded), not the base64 blob
DECODED=$($LOOPER -f "$CRONTAB" ls --json | \
  jq -r '.jobs[] | select(.id == "daily-inline") | .command')
echo "$DECODED" | grep -q "inline ok" || \
  fail "ls --json should show the decoded original script content"
pass "ls --json round-trips the original script source"

# No-shebang script should be rejected (don't guess interpreter)
NO_SHEBANG="$(mktemp)"
echo 'print("no shebang here")' > "$NO_SHEBANG"
if $LOOPER -f "$CRONTAB" add --id no-shebang --inline-script "$NO_SHEBANG" "0 9 * * *" 2>/dev/null; then
  fail "add --inline-script without shebang should be rejected"
fi
pass "add --inline-script rejects script without shebang"

# Oversized script should be rejected (>4KB encoded)
BIG_SRC="$(mktemp --suffix=.py)"
{ echo '#!/usr/bin/env python3'; head -c 6144 /dev/urandom | base64; } > "$BIG_SRC"
if $LOOPER -f "$CRONTAB" add --id too-big --inline-script "$BIG_SRC" "0 10 * * *" 2>/dev/null; then
  fail "add --inline-script over 4KB should be rejected with suggestion to use push"
fi
pass "add --inline-script enforces cron-line length cap"

rm -f "$INLINE_SRC" "$NO_SHEBANG" "$BIG_SRC"

echo "== #30 apply with [[file]] + [[job]] (atomic deployment) =="

DEPLOY_SCRIPT="$(mktemp --suffix=.py)"
cat > "$DEPLOY_SCRIPT" <<'EOF'
#!/usr/bin/env python3
print("from deploy spec")
EOF

DEPLOY_REMOTE="$SIM_REMOTE/deploy/scrape.py"
SPEC="$(mktemp --suffix=.toml)"
cat > "$SPEC" <<EOF
[[file]]
id = "scrape-script"
local = "$DEPLOY_SCRIPT"
remote = "$DEPLOY_REMOTE"
mode = "0755"

[[job]]
id = "scrape-cron"
schedule = "0 8 * * *"
command = "python3 $DEPLOY_REMOTE"
requires = ["scrape-script"]
EOF

# Atomic apply: both file and job land
$LOOPER -f "$CRONTAB" --as agent-a apply "$SPEC" || \
  fail "apply with [[file]] block should succeed"
[ -f "$DEPLOY_REMOTE" ] || fail "apply should have pushed the script"
$LOOPER -f "$CRONTAB" ls --json | jq -e '.jobs[] | select(.id == "scrape-cron")' >/dev/null || \
  fail "apply should have installed the cron job"
pass "apply deploys file + job atomically"

# Idempotent: re-apply produces no writes
SHA_BEFORE=$(shasum "$DEPLOY_REMOTE" "$CRONTAB" | shasum)
$LOOPER -f "$CRONTAB" --as agent-a apply "$SPEC"
SHA_AFTER=$(shasum "$DEPLOY_REMOTE" "$CRONTAB" | shasum)
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || fail "re-applying unchanged spec should not modify anything"
pass "apply is idempotent across files + jobs"

# Plan exits 0 on convergence, nonzero on drift
$LOOPER -f "$CRONTAB" plan "$SPEC" >/dev/null || fail "plan should exit 0 on convergence"
echo "# drift comment" >> "$DEPLOY_SCRIPT"
if $LOOPER -f "$CRONTAB" plan "$SPEC" >/dev/null 2>&1; then
  fail "plan should exit nonzero when local script content has changed"
fi
pass "plan detects file-content drift"

# Atomicity: spec with a broken cron command should roll back the file push
BAD_SPEC="$(mktemp --suffix=.toml)"
BAD_REMOTE="$SIM_REMOTE/deploy/rollback-target.py"
cat > "$BAD_SPEC" <<EOF
[[file]]
id = "rollback-script"
local = "$DEPLOY_SCRIPT"
remote = "$BAD_REMOTE"

[[job]]
id = "broken-job"
schedule = "this is not a valid schedule at all"
command = "python3 $BAD_REMOTE"
requires = ["rollback-script"]
EOF

if $LOOPER -f "$CRONTAB" --as agent-a apply "$BAD_SPEC" 2>/dev/null; then
  fail "apply with invalid schedule in [[job]] should fail"
fi
[ ! -f "$BAD_REMOTE" ] || fail "apply must roll back the file push when the job step fails"
pass "apply rolls back file pushes on partial failure"

# destroy removes everything declared in spec
$LOOPER -f "$CRONTAB" --as agent-a destroy "$SPEC" || \
  fail "destroy should succeed"
[ ! -f "$DEPLOY_REMOTE" ] || fail "destroy should remove pushed files"
$LOOPER -f "$CRONTAB" ls --json | jq -e \
  '[.jobs[] | select(.id == "scrape-cron")] | length == 0' >/dev/null || \
  fail "destroy should remove declared jobs"
pass "destroy is the symmetric inverse of apply"

rm -f "$DEPLOY_SCRIPT" "$SPEC" "$BAD_SPEC"

echo "== #31 credential-passthrough contract documented =="

# No code to test — verify the documentation contract exists
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

grep -qiE "ssh.?auth.?sock|credential.?passthrough|never stores ssh" "$REPO_ROOT/CLAUDE.md" || \
  fail "CLAUDE.md should document the credential-passthrough contract"
pass "CLAUDE.md documents credential-passthrough"

grep -qiE "ssh.?agent|IdentityFile" "$REPO_ROOT/README.md" || \
  fail "README.md should show the three supported ssh credential patterns"
pass "README.md shows credential patterns"

grep -qiE "credential|keyring|key.?manager" "$REPO_ROOT/ROADMAP.md" && \
  grep -qiE "out of scope|non-goal|reject" "$REPO_ROOT/ROADMAP.md" || \
  fail "ROADMAP.md should explicitly mark credential storage as out of scope"
pass "ROADMAP.md marks credential storage as out of scope"

echo
echo "v0.4 acceptance passed"
