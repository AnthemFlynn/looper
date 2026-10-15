# Working with Orca's capabilities in mind

Knowing *how* to run Orca commands is half the skill. The other half is noticing *when* Orca changes
what the best plan is. In a plain terminal you are one agent with one checkout, working serially,
and the human can't see you until you reply. Inside Orca you are one member of a fleet. Spare
checkouts, other agents, a live status channel to the human, a browser and a scheduler are all
one command away. An agent that ignores them works as if it were alone. An agent that grabs them
all the time burns the user's money and attention. This file is about telling the two situations
apart.

## Contents

1. What you have that a lone agent doesn't
2. Moments that should make you think of Orca
3. When not to reach for it
4. Propose or just do it: autonomy calibration
5. Being a good member of the fleet

---

## 1. What you have that a lone agent doesn't

| Capability | What it changes about how you work |
| --- | --- |
| **Cheap, isolated checkouts** (`worktree create`) | Trying an alternative no longer risks your current state. A spike, a risky refactor or a "what if" can live in a throwaway worktree while your branch stays clean. |
| **Other agents and models on demand** (`--agent`, `agent launch`) | You can get a second opinion, an independent review, parallel hands, or best-of-N from different models. Different agents make different mistakes, so where they agree is evidence and where they disagree is the hard part. |
| **A status channel to the human** (card comment, `--workspace-status`, `--unread`) | The human watches a sidebar, not your tab. You can keep them informed without interrupting, and you can ask for attention when it really matters. |
| **A real browser per worktree** | "The UI works" becomes a claim with evidence: a snapshot, a screenshot, console and network logs. |
| **Memory of past agent sessions** (`orca search`) | "Has anyone hit this error before, and what did they try?" can be answered from transcripts across all your agents. |
| **An ownership map** (`reference find`) | You can find which agent is already on a PR or ticket before you duplicate its work. |
| **A scheduler** (`automations`) | Recurring work (triage, dependency bumps, nightly checks) can run without anyone starting it. |
| **Remote compute** (`--host ssh:…`, `--environment`) | Heavy builds, GPUs or long jobs can run elsewhere while you stay responsive. |
| **Supervised parallelism** (orchestration) | Fan-out with accountability: every task ends with an explicit outcome, evidence, and cleanup. |

## 2. Moments that should make you think of Orca

Each moment, paired with the move to consider:

- **You aren't sure which approach is right, the bug is intermittent, or you've already failed
  once.** Race two or three agents on the same brief, or spike the alternative in a throwaway
  worktree. This is the strongest case. Sequential retries cost the same wall-clock time and
  give you less information.
- **The task splits into parts that touch disjoint files.** Hand each part off to its own
  worktree. If you'll need to merge or check the results, supervise it instead (orchestration).
- **You just finished a change you're not fully sure of.** Launch a different agent or model in
  read-only review mode on your branch. A fresh model catches what you have become blind to.
- **You found something real but out of scope** (a second bug, a refactor, a flaky test). Hand
  it off to a new worktree, or note it on your card. Don't widen your own diff.
- **You're about to say a UI change works.** Verify it in the built-in browser first and attach
  the screenshot.
- **You're starting on an error, a ticket or a PR.** `reference find` checks whether someone owns
  it. `search "<exact error text>"` checks whether another session already dug into it.
- **You hit a long wait** (CI, a big build, an upstream answer). Checkpoint your card with what
  you're waiting on, then hand off or move on. Don't spin.
- **A decision needs the human.** Put the question in your card comment and set `--unread`.
  Chat text in a tab they aren't watching may go unseen for hours.
- **The user asks for the same thing for the third time.** Propose an automation.
- **The work needs more compute than this machine has.** Check `host list` for a bigger target.

## 3. When not to reach for it

Orca makes spawning work cheap for *you*. It is not cheap for the user. Every extra agent uses
their subscription and rate limits, and every extra worktree is something they have to review.

- **Small, clear tasks:** just do them. A rule of thumb is to race only when you'd otherwise
  expect to need more than one attempt.
- **Overlapping files:** parallel agents on the same files collide at merge time. Split work by
  file ownership, or keep it serial.
- **The user's review time is the real bottleneck.** Default to at most three parallel agents.
  More than that is something to ask about first.
- **Risky operations:** spawned agents usually run with permission prompts off (Yolo), and a
  worktree isolates git state, not access. Don't hand production credentials, destructive
  migrations or untrusted input to an unsupervised agent.
- **Delegating to avoid thinking:** a vague brief to three agents gives you three vague results.
  The quality of the brief decides the outcome. Spend the effort there.
- **The whole fleet:** don't poll every agent "to stay informed". Read state when a decision
  depends on it.

## 4. Propose or just do it: autonomy calibration

Split moves by cost and reversibility:

**Just do it.** These are cheap, reversible, or inside your own worktree:
- checkpoint your card (comment and status)
- read-only queries: `status`, `worktree ps`, `search`, `reference find`, `terminal read`
- verifying your own UI in your worktree's browser
- creating and later removing your *own* scratch worktree for a quick spike, when the user has
  already asked you to explore

**Propose it in one line, then act on a yes.** These spend the user's resources or attention:
- launching other agents (races, handoffs, reviewers), especially more than one, or expensive
  models
- creating automations, publishing artifacts, or using remote hosts
- anything that touches another agent's worktree or terminal

A good proposal names the move, the reason and the cost, for example: *"This flake has resisted
two fixes. Want me to race codex and claude on it in parallel worktrees? About 20 minutes,
two agent sessions."* If the user has said something like "use as many agents as you need" or
"just hand it off", that standing permission covers the matching moves for the rest of the task.

## 5. Being a good member of the fleet

- Your card is how the human sees you. Keep it true, short and current.
- Leave reviewable work: commits on your branch, a summary of what changed and what's left.
- Talk to other agents through Orca (`terminal send`, orchestration messages), never by editing
  their worktrees.
- Clean up what you created and know to be disposable. Ask about everything else.
- Report what receipts prove, not what you hope happened.
