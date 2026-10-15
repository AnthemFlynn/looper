#!/usr/bin/env bash
# SessionStart hook: when Claude Code starts inside an Orca terminal, tell the model so it
# reports progress back into Orca. Env-only (no CLI calls) so it is instant and can never block
# session start; the model confirms identity with `orca worktree current --json`.
# Outside Orca it prints nothing.
set -u

if [ -z "${ORCA_WORKTREE_ID:-}" ] && [ -z "${ORCA_TERMINAL_HANDLE:-}" ]; then
  exit 0
fi

if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
  cli="$ORCA_CLI_COMMAND"
elif [ -n "${ORCA_DEV_REPO_ROOT:-}" ]; then
  cli="orca-dev"
elif [ -n "${ORCA_CLI_BIN_DIR:-}" ] && [ -x "${ORCA_CLI_BIN_DIR}/orca" ]; then
  cli="${ORCA_CLI_BIN_DIR}/orca"
elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
  cli="orca-ide"
else
  cli="orca"
fi

ctx="This session is running inside an Orca-managed terminal"
[ -n "${ORCA_WORKTREE_PATH:-}" ] && ctx="$ctx (worktree path: ${ORCA_WORKTREE_PATH})"
ctx="$ctx. Orca CLI for this session: \`$cli\`. Use the orca skill: confirm your workspace with \`$cli worktree current --json\`, and keep the workspace card current at real checkpoints with \`$cli worktree set --worktree active --comment \"...\" --json\` (read the existing comment first). Address other agents and worktrees through the Orca CLI with --json. You are one agent in a fleet: when it would help, use parallel worktrees, a second agent as reviewer, browser verification, or past-session search (orca search). Propose anything that launches agents or spends the user's resources first. These env-derived hints can be stale; trust the CLI's answers."

# Minimal JSON string escaping for the values above (backslash, quote, tab, newline).
esc=$(printf '%s' "$ctx" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
