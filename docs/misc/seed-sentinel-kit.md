# PROJECT: sentinel-kit

Build a Python (or TypeScript) library + CLI that scaffolds "sentinel agents":
small, cron-fired LLM-using processes that synthesize over a domain and publish
signals for a main agent to consume. Sentinels run on top of `looper` and use
`looper publish` to emit synthesized output.

## Purpose

Eliminate boilerplate for engineers who write sentinel agents. The kit handles:

- Wake-loop scaffolding (drain events since last cursor, hand to engineer)
- Query-entry-point scaffolding (sentinel answers actor's BLUF / in-depth asks)
- Cursor + state persistence (default sqlite, swappable)
- Looper CLI invocation helpers (typed wrappers around `history`, `publish`, etc.)
- Declarative deployment via `looper apply`

**The kit does not ship synthesis.** The engineer writes `synthesize()` with
their own prompts, LLM client, and domain logic. The kit handles everything
around it.

## Target shape of an engineer's sentinel

```python
from sentinel_kit import Sentinel

sentinel = Sentinel(name="research-watch", owner="agent-a")

@sentinel.source(id="rss", schedule="*/15 * * * *", command="curl ...")
@sentinel.source(id="github", schedule="*/5 * * * *", command="gh api ...")
def _watchers(): pass

@sentinel.wake(schedule="*/30 * * * *")
def synthesize(events, memory):
    # engineer's domain logic — uses their LLM client, prompts, memory ops
    summary = my_llm.summarize(events, context=memory.recent())
    memory.append(summary)
    return summary  # auto-published via looper publish

@sentinel.query
def answer(question, depth, memory):
    return memory.bluf(question) if depth == "bluf" else memory.indepth(question)

if __name__ == "__main__":
    sentinel.run()  # routes argv: wake | query | init | deploy
```

## Hard constraints

1. **Opinion-light on synthesis.** No prescribed LLM client. No prescribed prompts.
   The kit provides the loop; the engineer provides the brain.
2. **Looper is the backend.** Persistent operations route through `looper` CLI.
   The kit does not invent its own event log or scheduling.
3. **Memory is a convenience default, not a lock-in.** Ship a sqlite-backed
   `memory` helper; let engineers swap in anything that quacks like it.
4. **The wake function is where the brain goes.** Everything else is plumbing.

## Deliverables (first milestone)

1. `Sentinel` class + `@source`, `@wake`, `@query` decorators
2. `sentinel run {wake|query|init|deploy}` CLI dispatch
3. `sentinel init <name>` — generates template project (script + manifest)
4. `sentinel deploy` — translates definition into `looper apply` calls
5. `sentinel run-locally {wake|query}` — sandboxed test harness
6. Default sqlite-backed memory helper
7. Cursor persistence under user's data dir
8. Three example sentinels: research-watch (RSS + GH), service-health, pricing-watch

## Out of scope

- The `synthesize()` body (engineer's domain)
- Bundled LLM clients
- Prompt libraries
- Anything beyond a default convenience memory store
- Looper-the-binary changes
