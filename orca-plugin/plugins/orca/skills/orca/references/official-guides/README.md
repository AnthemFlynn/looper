# Orca's official agent guides (offline copy)

These are the guides Orca's CLI prints with `orca skills get <topic>`, copied from
[stablyai/orca](https://github.com/stablyai/orca) `skill-guides/` at Orca 1.4.214 (MIT, see
`LICENSE-orca.txt`). In the files, `ORCA` stands for the CLI executable you resolved.

**Prefer the live command whenever the CLI is installed.** It is matched to the binary that will
run your commands, and these copies can lag behind:

```bash
orca skills get orca-cli
orca skills get orchestration --references               # list references
orca skills get orchestration --reference recovery-and-cleanup
```

| File | Topic |
| --- | --- |
| `orca-cli.md` (+ `orca-cli/references/`) | Worktrees, terminals, handoffs, references, search; browser, automations, publishing |
| `orchestration.md` (+ `orchestration/references/`) | Supervised Runs, Tasks, Dispatches, workers, messaging, gates, recovery |
| `computer-use.md` | `orca computer` desktop-app automation |
| `orca-linear.md`, `orca-jira.md` | Ticket read/write via `orca linear` / `orca jira` |
| `orca-emulator.md`, `orca-emulator-android.md` | iOS Simulator / Android emulator control |
| `orca-per-workspace-env.md` (+ references) | `orca.yaml` environment recipes: Docker, SSH, Vercel sandboxes |
