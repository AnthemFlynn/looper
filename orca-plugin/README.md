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
    │   ├── SKILL.md                       # the hub: Orca mindset, orient, API contract, mechanism picker, workflows, safety
    │   ├── scripts/orca.sh                # resolves the right CLI (orca / orca-ide / orca-dev / shim) and runs it
    │   ├── scripts/build_reference.py     # regenerates references/commands from `orca agent-context --json`
    │   ├── scripts/mock_orca.py           # fake CLI for dry-running Orca scripts without Orca installed
    │   └── references/
    │       ├── operating-model.md         # when Orca changes the plan: triggers, anti-patterns, propose-vs-do
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

### How it relates to Orca's built-in skills

It is designed to **layer on top of** Orca's own skills, not replace them. Install both:

```bash
orca skills install --skill orca-cli --skill orchestration    # or: npx skills add https://github.com/stablyai/orca --skill orca-cli --skill orchestration
```

| Layer | Provided by | Covers |
| --- | --- | --- |
| *What to do*: knowing when Orca changes the plan | this plugin (`references/operating-model.md`, SKILL.md §0) | when to race, hand off, get a second-agent review, verify in the browser, search past sessions; when not to; what to propose vs just do |
| *How agents call Orca safely* | this plugin (`references/api-contract.md`) | JSON envelope, selectors, receipts, idempotent retries, error recovery, host scoping |
| *Exactly which command and flags*, version-matched | Orca's `orca-cli` / `orchestration` skills (via `orca skills get`) | authoritative command rules for the installed build |
| Workflows, offline references, slash commands, subagent, hook, mock CLI | this plugin | end-to-end recipes and tooling |

When both trigger, the skill tells agents to use this one to decide *what* to do and Orca's for
*exactly how*. If they ever disagree on a command detail, Orca's live guide wins.

## Slash commands

| Command | Does |
| --- | --- |
| `/orca:status` | Runtime health plus every workspace grouped as Needs you / Working / Done |
| `/orca:checkpoint [msg]` | Updates this worktree's card comment/status (reads it first) |
| `/orca:race <task> [--agents claude,codex]` | Same brief to N agents in parallel worktrees, compare, recommend a winner |
| `/orca:handoff <task> [--agent codex]` | Full ownership transfer to a fresh agent in a new worktree |
| `/orca:supervise <objective>` | Supervised orchestration run (Experimental feature in Orca) |
| `/orca:refresh-reference` | Regenerates the command reference from your installed Orca |

## Evals

`evals/evals.json` holds three realistic prompts (hand off a task, write a race script, set up
`orca.yaml`) with assertions. `evals/grade.py` grades them programmatically. Eval 1 runs against
`mock_orca.py` (symlinked as `orca-ide`) and checks the exact CLI calls the agent made.
`evals/iteration-1-review.html` is the side-by-side review of iteration 1: the skill passed
100% of assertions, the no-skill baseline 87%. The baseline missed the independent-worktree
handoff, used an invalid selector form, and didn't check the JSON envelope.

## Keeping it current

The snapshots describe Orca 1.4.214. After upgrading Orca, run `/orca:refresh-reference` (or
`python3 plugins/orca/skills/orca/scripts/build_reference.py`) in this source checkout and commit
the result. The live CLI always wins over the snapshots, and the skill tells agents so.

Docs and guide snapshots are © Lovecast Inc., MIT-licensed (see `references/official-guides/LICENSE-orca.txt`).
