# Orca configuration and settings that matter to agents

Full docs: `docs/model__orca-yaml.md`, `docs/settings.md`, `docs/model__worktrees.md`,
`official-guides/orca-per-workspace-env.md` (cloud VM / Docker / SSH env recipes).

## orca.yaml (repo root, commit it)

```yaml
scripts:
  setup: |
    pnpm install
  archive: |
    echo "Workspace archived"
setupAgentStartupPolicy: wait-for-setup   # or start-immediately (default)
issueCommand: |
  echo "Linked item: {{artifact_url}}"
defaultTabs:
  - title: Agent            # first tab: no command; the composer's agent takes it
  - title: Dev server
    command: pnpm dev
    color: "#4493F8"
worktree:
  sharedDirectories:        # existing, gitignored dirs only; always linked, edits are shared
    - .cache
environmentRecipes: []      # per-workspace envs; see official-guides/orca-per-workspace-env.md
```

Rules that cause silent failures:

- **Invalid YAML or any duplicate key rejects the whole file.** Setup, tabs and shared dirs all
  stop applying together. Many YAML linters accept duplicate keys. Orca does not.
- **Which checkout is read:** setup script, `setupAgentStartupPolicy` and `defaultTabs` come from
  the *new worktree's* `orca.yaml`. `sharedDirectories`, `.worktreeinclude`, the archive script
  and `issueCommand` come from the *primary checkout* (the folder registered in Orca). Editing them
  on a feature branch does nothing until the primary checkout has them.
- `setupRunPolicy` and `commandSourcePolicy` are Settings values, not YAML keys.
- In the desktop create composer, the agent takes the first tab, so the first tab's command
  doesn't run. CLI `worktree create --agent` adds a separate startup terminal, so every tab
  command can run there.
- Tab commands don't wait for setup. A dev server that needs `node_modules` should go in setup
  or start after it.
- Setup runs under Bash with `set -e` on macOS/Linux and `.cmd` on Windows. Env vars:
  `ORCA_ROOT_PATH`, `ORCA_WORKTREE_PATH`, `ORCA_WORKSPACE_NAME`.
- Limits: 256 KiB file, 64 KiB per string, 256 tabs/recipes, first 100 shared dirs.
- A valid file does not bypass Orca's command-approval prompt for shared commands.

## .worktreeinclude (primary checkout)

One literal, root-anchored path per line for gitignored files to **copy** privately into each new
worktree. Typical entries: `.env`, `.env.local`, `.vscode/settings.json`. No globs, no `!`
negation, no inline comments. Only existing, gitignored entries are copied. Budget: 2 GiB and
50k entries per worktree. Check with `git check-ignore -- <path>` in the primary checkout.

Sharing vs copying: Settings → Repository → Worktree Shared Paths (clone-copy or link) is applied
first, then `sharedDirectories` (always a link), then `.worktreeinclude` (always a private copy).

## CLI equivalents for setup behavior

- `worktree create --setup run|skip|inherit` (`inherit` follows Settings → Repository).
- `worktree rm --run-hooks` enables the archive script. A failed archive hook blocks removal.
- `repo set-base-ref --repo id:<id> --ref origin/main` before mass-creating worktrees.

## Settings only a human can change

No CLI flag grants these. When a command fails because one is off, name the setting and stop.

| Setting | Effect for agents |
| --- | --- |
| Settings → General → Orca CLI | Registers `orca` / `orca-ide` on PATH |
| Settings → Agents → Agent Permissions (Yolo / Manual) | Yolo (the default) launches agents with their bypass flag (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, `--yolo`, …). Per-agent custom args opt out |
| Settings → Agents → Agent status hooks | Working/waiting/done dots. CLI can toggle: `orca agent hooks on/off/status` |
| Settings → Experimental → Chat UI | Whether launches open as a chat (`structured`) or a terminal |
| Settings → Experimental (orchestration, Agent Dashboard, hibernation, Cloud VM) | Orchestration commands need this enabled |
| Settings → Artifacts → Allow publishing public artifact links | Gate for `artifacts share/update` (`artifact_sharing_disabled`) |
| Settings → Share Skills → Allow agents and the Orca CLI to publish skill links | Gate for `skills share` (`agent_skill_sharing_disabled`) |
| Settings → Agent Session History (search indexing) | Gate for `orca search`; check `orca search --index-status --json` |
| Settings → Integrations (Linear, Jira, GitHub, MCP) | Required before `orca linear` / `orca jira` work |
| Settings → SSH / Remote Orca Servers | Targets that appear in `orca host list` |

## Agent hooks and memory

- Orca runs each repo's `.claude/` and `.codex/` hooks when it launches agents there, and leaves
  `CLAUDE.md` / `AGENTS.md` alone.
- Orca-managed status hooks write their endpoint to `{userData}/agent-hooks/endpoint.env` and
  re-source it on each invocation, so long sessions survive app restarts.
- Skills: `orca skills install --skill orca-cli --skill orchestration` (or `--all --dry-run`)
  installs Orca's own stubs for detected agents. `orca skills update --all` refreshes them to the
  running build. Orca scans Claude, Codex, Agent Skills and OMP skill homes.
