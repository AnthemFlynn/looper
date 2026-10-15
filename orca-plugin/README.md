# Orca plugin for Claude Code

A Claude Code plugin (and portable Agent Skill) for working with [Orca](https://www.onorca.dev/docs),
the desktop IDE that runs many coding agents in parallel git worktrees. It teaches agents to use
Orca's CLI as an API (`--json` envelopes, selectors, receipts, idempotent retries, error recovery)
and gives you slash commands for the workflows you use most.

## What's inside

```
orca-plugin/
├── .claude-plugin/marketplace.json        # lets you install this folder as a plugin marketplace
└── plugins/orca/
    ├── .claude-plugin/plugin.json
    ├── skills/orca/
    │   ├── SKILL.md                       # the hub: orient, API contract, mechanism picker, workflows, safety
    │   ├── scripts/orca.sh                # resolves the right CLI (orca / orca-ide / orca-dev / shim) and runs it
    │   ├── scripts/build_reference.py     # regenerates references/commands from `orca agent-context --json`
    │   └── references/
    │       ├── api-contract.md            # envelope, discovery, identity, receipts, errors, retries, hosts, paging
    │       ├── workflows.md               # 16 step-by-step recipes
    │       ├── orchestration.md           # router + cheat sheet for supervised multi-agent runs
    │       ├── config-and-settings.md     # orca.yaml, .worktreeinclude, human-only settings
    │       ├── commands/                  # all 281 CLI commands, grouped by job (generated)
    │       ├── official-guides/           # Orca's own version-matched agent guides (offline copy, MIT)
    │       └── docs/                      # offline snapshot of onorca.dev/docs (58 pages)
    ├── commands/                          # /orca:status /orca:checkpoint /orca:race /orca:handoff /orca:supervise /orca:refresh-reference
    ├── agents/orca-fleet-reporter.md      # read-only subagent: "what are all my agents doing?"
    └── hooks/                             # SessionStart: detects an Orca terminal and primes the session
```

## Install

**Claude Code (plugin):**

```text
/plugin marketplace add AnthemFlynn/looper   # if this folder is moved to its own repo, use that repo instead
/plugin install orca@orca-tools
```

or from a local clone: `/plugin marketplace add ./orca-plugin`, then `/plugin install orca@orca-tools`.

**Other agents (Codex, OpenCode, Pi, …) via Agent Skills:** copy or symlink
`plugins/orca/skills/orca` into the agent's skills directory (for example `~/.agents/skills/orca`,
`~/.codex/skills/orca`, or `~/.claude/skills/orca`). Orca's own Skills page scans those homes.

This plugin works alongside Orca's official stubs (`npx skills add https://github.com/stablyai/orca
--skill orca-cli --skill orchestration`). They load the version-matched guide from your binary.
This skill adds the agent-API contract, the workflow playbook, offline references and the slash
commands, and it defers to `orca skills get` whenever the CLI is present.

## Slash commands

| Command | Does |
| --- | --- |
| `/orca:status` | Runtime health plus every workspace grouped as Needs you / Working / Done |
| `/orca:checkpoint [msg]` | Updates this worktree's card comment/status (reads it first) |
| `/orca:race <task> [--agents claude,codex]` | Same brief to N agents in parallel worktrees, compare, recommend a winner |
| `/orca:handoff <task> [--agent codex]` | Full ownership transfer to a fresh agent in a new worktree |
| `/orca:supervise <objective>` | Supervised orchestration run (Experimental feature in Orca) |
| `/orca:refresh-reference` | Regenerates the command reference from your installed Orca |

## Keeping it current

The snapshots describe Orca 1.4.214. After upgrading Orca, run `/orca:refresh-reference` (or
`python3 plugins/orca/skills/orca/scripts/build_reference.py`) in this source checkout and commit
the result. The live CLI always wins over the snapshots, and the skill tells agents so.

Docs and guide snapshots are © Lovecast Inc., MIT-licensed (see `references/official-guides/LICENSE-orca.txt`).
