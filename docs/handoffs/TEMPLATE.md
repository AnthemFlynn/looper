<!--
Copy this file to docs/handoffs/YYYY-MM-DD-<slug>.md and fill it in.
Delete this comment and any prompts you don't need. Keep it honest:
a half-true "everything's green" handoff is worse than none.
-->

# Handoff — YYYY-MM-DD — <one-line title>

**Session:** <date · rough duration>
**Branch left on:** `<branch>` @ `<short SHA>`
**Sanity at stop:** <e.g. `zig build test` 346/346 · ReleaseSafe cross-builds green · working tree clean>

---

## Part 1 — For the senior dev (the *why*)

> Skim-readable. Decisions, trade-offs, risk, and anything needing your call.

### TL;DR
<2–4 sentences. Where the project is now and what moved this session.>

### Decisions made (and why)
- **<decision>** — <rationale, and the alternative you rejected>.

### Deliberately deferred
- **<thing>** — <why now isn't the time; where it's tracked (issue #)>.

### Risks & landmines
- <what could bite, blast radius, and why it's mitigated or acceptable>.

### Needs your judgment
- <anything awaiting a lead's call — or "nothing; clean stopping point">.

---

## Part 2 — For the next dev (the *how*)

> Everything needed to pick up the baton without re-deriving the session.

### Current state — verify before trusting
- **Default branch:** <>
- **Branches:** <>
- **Open PRs:** <#num base←head — state>
- **Key SHAs:** main @ `<>` · dev @ `<>`
- **CI:** <green/red · where>
- **Tests:** <count>

### Get to a working state
```sh
<exact commands to build, test, and run the app from a clean checkout>
```

### ▶ Do this next
<The single most important next action — concrete enough to start in one command.
If several, rank them and ★ the first.>

### Open loops / in-flight
- <anything half-done, with exact `file:line` / branch / PR — or "none; stopped clean">.

### Gotchas
- <things invisible from the code: a config quirk, a flag, a trap you already hit>.

### Backlog pointers
- <issue #s with a one-line each, so the next person can pick by priority>.
