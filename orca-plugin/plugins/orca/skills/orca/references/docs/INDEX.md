# Orca docs snapshot

Offline copy of https://www.onorca.dev/docs (Orca 1.4.214). Use it when the site is unreachable, or grep it for a setting or concept. Product behavior changes between releases; the live CLI (`orca skills get <topic>`, `orca <command> --help`) wins on any conflict.

| Page | Title | What it covers |
|---|---|---|
| [index.md](index.md) | What is Orca? | A 60-second pitch: who Orca is for and when to reach for it. |
| [install.md](install.md) | Install | Download Orca for macOS, Windows, or Linux, and opt into RC builds. |
| [first-session.md](first-session.md) | Your first 3-agent session | From empty app to three agents running in parallel in under five minutes. |
| [model__worktrees.md](model__worktrees.md) | Worktrees | How Orca turns every feature or bug into its own git worktree. |
| [model__orca-yaml.md](model__orca-yaml.md) | orca.yaml & .worktreeinclude | Local worktree setup, terminal defaults, shared directories, and copied files. |
| [model__tabs-panes-splits.md](model__tabs-panes-splits.md) | Tabs, panes & split layouts | Drag-to-split panes, tab groups, and pinned boundaries. |
| [model__agents-sessions.md](model__agents-sessions.md) | Agents & sessions | State dots, restart chips, and the lifecycle of an agent session. |
| [model__session-restore.md](model__session-restore.md) | Session restore | Quit Orca, reopen it, and pick up exactly where you left off — worktrees, splits, scrollback, focused tab. |
| [model__quick-open.md](model__quick-open.md) | Quick Open & Jump Palette | Cmd-J scoped jump across worktrees, recents, and tabs. |
| [agents__supported.md](agents__supported.md) | Supported agents | Every agent Orca ships with out of the box. |
| [agents__claude-code.md](agents__claude-code.md) | Claude Code in Orca |  |
| [agents__glm-agent.md](agents__glm-agent.md) | How to use GLM-5.2 in Orca ADE | Configure Claude Code and other CLI agent harnesses to run GLM-5.2 inside Orca worktrees. |
| [agents__codex.md](agents__codex.md) | Codex in Orca |  |
| [agents__cursor-cli.md](agents__cursor-cli.md) | Cursor CLI in Orca |  |
| [agents__codex-hot-swap.md](agents__codex-hot-swap.md) | Hot-swap Codex accounts |  |
| [agents__native-chat.md](agents__native-chat.md) | Chat UI (native chat) | Optional chat surface over supported agent terminals — skills, model pickers, and transcript view. |
| [agents__session-history.md](agents__session-history.md) | Agent session history | Browse and resume past Claude, Codex, Cursor, Gemini, and other agent sessions from Orca's right sidebar. |
| [agents__hibernation.md](agents__hibernation.md) | Agent hibernation | Let Orca pause idle background agent terminals and auto-resume them when you reopen the worktree. |
| [agents__usage-tracking.md](agents__usage-tracking.md) | Usage & rate-limit tracking |  |
| [agents__hooks-memory.md](agents__hooks-memory.md) | Agent hooks & memory |  |
| [review__diff-viewer.md](review__diff-viewer.md) | Diff viewer |  |
| [review__annotate-ai-diff.md](review__annotate-ai-diff.md) | Annotate AI Diff |  |
| [review__attribution.md](review__attribution.md) | Attribution |  |
| [review__commit-push.md](review__commit-push.md) | Commit & push from Orca |  |
| [review__github.md](review__github.md) | Hosted reviews, issues & Actions |  |
| [review__linear.md](review__linear.md) | Linear items drawer |  |
| [review__jira.md](review__jira.md) | Jira items drawer | Browse, edit, and link Jira Cloud or self-hosted Server/Data Center issues to worktrees the same way you link Linear or GitHub items. |
| [editing__monaco.md](editing__monaco.md) | Monaco editor & autosave |  |
| [editing__markdown.md](editing__markdown.md) | Rich markdown editor |  |
| [editing__viewers.md](editing__viewers.md) | HTML, Mermaid, PDF & image viewers |  |
| [editing__file-explorer.md](editing__file-explorer.md) | File explorer & external drag-drop |  |
| [browser__overview.md](browser__overview.md) | Per-worktree browser |  |
| [browser__design-mode.md](browser__design-mode.md) | Design Mode |  |
| [browser__profiles.md](browser__profiles.md) | Browser-use profiles |  |
| [terminal.md](terminal.md) | Terminal |  |
| [ways-to-run.md](ways-to-run.md) | Ways to run Orca | Local desktop, SSH hosts, self-hosted Orca servers, and on-demand per-workspace VMs — pick the right compute for each task. |
| [ssh.md](ssh.md) | SSH worktrees |  |
| [remote-servers.md](remote-servers.md) | Remote Orca Servers | Keep Orca running on another computer and connect from your laptop. |
| [cli__overview.md](cli__overview.md) | Orca CLI overview | Use the Orca CLI to script Orca from a terminal, manage worktrees, control agent terminals, automate the built-in browser, and install agent skills. |
| [cli__reference.md](cli__reference.md) | Orca CLI reference | Commands, selectors, and agent-friendly patterns for driving Orca from a shell. |
| [cli__orchestration.md](cli__orchestration.md) | Orchestration | Coordinate agents with Runs, tasks, supervised workers, messages, and decision gates. |
| [cli__automations.md](cli__automations.md) | Scheduled automations |  |
| [cli__computer-use.md](cli__computer-use.md) | Computer use | Drive local desktop apps from an agent via accessibility trees, screenshots, and safe UI actions. |
| [cli__worktree-checkpoints.md](cli__worktree-checkpoints.md) | Worktree checkpoints |  |
| [cli__skills.md](cli__skills.md) | Orca skills registry & MCP | Install Orca agent skills with npx skills add. Hybrid stubs stay thin; orca skills get serves the version-matched guide. Orca can update skills in the background. |
| [mobile.md](mobile.md) | Mobile companion | Pair the Orca mobile app to your desktop to monitor agents and unstick worktrees from your phone. |
| [android-apk.md](android-apk.md) | Install Orca Mobile on Android | Download and install Orca Mobile on Android. |
| [notifications.md](notifications.md) | Notifications & Inbox |  |
| [activity.md](activity.md) | Agents feed | Threaded feed of agent completions, blocking states, response previews, and worktree creation events across every worktree. |
| [recipes__parallel-agents.md](recipes__parallel-agents.md) | Race three agents on the same task |  |
| [recipes__review-ai-diff.md](recipes__review-ai-diff.md) | Review an AI diff line-by-line |  |
| [recipes__jump-worktrees.md](recipes__jump-worktrees.md) | Jump between 10 worktrees |  |
| [recipes__design-mode-fix.md](recipes__design-mode-fix.md) | Fix a UI bug with Design Mode |  |
| [recipes__remote-worktrees.md](recipes__remote-worktrees.md) | Work on a remote machine over SSH |  |
| [settings.md](settings.md) | Settings reference |  |
| [telemetry.md](telemetry.md) | Privacy & Telemetry | What anonymous usage data Orca collects, what it never collects, and how to opt out. |
| [troubleshooting.md](troubleshooting.md) | Troubleshooting & FAQ |  |
| [github-errors.md](github-errors.md) | Troubleshooting GitHub errors | Diagnose rate limits, auth failures, and other GitHub CLI errors in Orca PR checks, Tasks, and Source Control. |
