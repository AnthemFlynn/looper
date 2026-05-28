# Session handoffs

A handoff is what you write when you stop, so the next session — you next week, a
teammate, or an AI agent — resumes with everything you were holding in your head
and none of the time you spent earning it lost.

The rule of thumb: **end every working session with a handoff.** If you did
enough to be worth resuming, you did enough to be worth handing off.

## Why two audiences

Every handoff is written for two readers, because they need opposite things:

- **The senior dev** wants the *why*. What you decided, what you traded away,
  what's risky, what needs their judgment. They skim to answer: *"Is this on
  track, and is there anything I have to weigh in on?"*
- **The next dev — the one taking the baton** wants the *how*. Exactly where
  things stand, where everything lives, the one thing to do next, and what will
  trip them up. They read to answer: *"How do I pick this up and keep moving
  without re-deriving what already happened?"*

A handoff with only status leaves the next person re-making decisions you already
made. One with only narrative leaves them hunting for the branch. You need both —
so the template has a section for each.

## Where they live

`docs/handoffs/YYYY-MM-DD-<slug>.md`, one per session. The newest is the live
baton:

```sh
ls docs/handoffs/[0-9]*.md | sort | tail -1     # the current baton
```

Dated files are immutable session records. Git versions them; the history *is*
the point — "why did we do X two sessions ago" stays answerable.

## Starting a session

Read the latest handoff first — it names the branch, the build/test commands, the
open loops, and the single next action. **Verify its "current state" claims**
(branch SHA, CI status, test count) before trusting them: they were true when
written, not necessarily now.

## Ending a session

Copy [TEMPLATE.md](TEMPLATE.md) to `docs/handoffs/<today>-<slug>.md`, fill both
parts, commit. Quality bar:

- [ ] **TL;DR** a stranger could read and know where things stand.
- [ ] Every non-obvious **decision, with the *why*** — and the option you didn't take.
- [ ] What you **deferred and why**, so it reads as a choice, not an oversight.
- [ ] **Verifiable state**: branch, default branch, open PRs, key SHAs, CI, test count.
- [ ] **The single next action**, concrete enough to start in one command.
- [ ] **Gotchas** the next person cannot see from the code alone.

### Committing a handoff

Handoffs commit **directly to `dev`** — they are session logs, not code, and
gating "I'm done for the day" on a CI round-trip defeats the entire purpose. This
is the one deliberate exception to the PR-into-`dev` rule in
[CONTRIBUTING.md](../../CONTRIBUTING.md):

```sh
git add docs/handoffs/ && git commit -m "docs(handoff): <slug>" && git push origin dev
```

(The handoff *system* itself — this README and the template — was introduced via
a normal PR. Only the per-session entries take the direct-commit shortcut.)

## Relationship to the auto session summary

The `SessionStart` hook restores an `ECC:SUMMARY` / GSD checkpoint — a transcript
digest scraped from the last session. This handoff is its human-grade complement:
deliberate, curated, with decisions and a ranked next action. When both exist,
**the handoff wins** — it's what someone chose to say, not what a tool scraped.
