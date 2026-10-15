#!/usr/bin/env bash
# Resolve the right Orca CLI for this session and run it with the given arguments.
#
#   scripts/orca.sh status --json
#   scripts/orca.sh --which          # print the resolved executable and exit
#
# Resolution order (first match wins), mirroring Orca's own skill stubs:
#   1. $ORCA_CLI_COMMAND             Orca exports its launcher path into its terminals (incl. WSL)
#   2. orca-dev                      when $ORCA_DEV_REPO_ROOT is set (Orca dev checkout)
#   3. $ORCA_CLI_BIN_DIR/orca        inside an Orca terminal: Orca prepends its own CLI shim dir
#   4. orca-ide                      on Linux: /usr/bin/orca is the GNOME screen reader
#   5. orca                          macOS / Windows (Git Bash, MSYS)
#
# It never falls through to another binary when the chosen one is missing or fails:
# a different binary may target a different Orca build.
set -u

resolve() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    printf '%s\n' "$ORCA_CLI_COMMAND"
  elif [ -n "${ORCA_DEV_REPO_ROOT:-}" ]; then
    printf '%s\n' "orca-dev"
  elif [ -n "${ORCA_CLI_BIN_DIR:-}" ] && [ -x "${ORCA_CLI_BIN_DIR}/orca" ]; then
    printf '%s\n' "${ORCA_CLI_BIN_DIR}/orca"
  elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    printf '%s\n' "orca-ide"
  else
    printf '%s\n' "orca"
  fi
}

ORCA_BIN="$(resolve)"

if [ "${1:-}" = "--which" ]; then
  printf '%s\n' "$ORCA_BIN"
  exit 0
fi

# ORCA_CLI_COMMAND may be a path or a bare name; check both forms.
if ! command -v "$ORCA_BIN" >/dev/null 2>&1 && [ ! -x "$ORCA_BIN" ]; then
  {
    printf 'orca.sh: resolved Orca CLI "%s" is not on PATH.\n' "$ORCA_BIN"
    case "$ORCA_BIN" in
      orca-ide) printf 'On Linux, register it under Orca Settings -> General -> Orca CLI. Do not use /usr/bin/orca (screen reader).\n' ;;
      orca-dev) printf 'Build the dev CLI with `pnpm build:cli` in the Orca checkout.\n' ;;
      *)        printf 'Register it under Orca Settings -> General -> Orca CLI, or install Orca from https://onorca.dev/download.\n' ;;
    esac
  } >&2
  exit 127
fi

exec "$ORCA_BIN" "$@"
