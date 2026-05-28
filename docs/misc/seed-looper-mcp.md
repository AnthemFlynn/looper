# PROJECT: looper-mcp

Build the MCP (Model Context Protocol) server for `looper`. Looper is a Zig CLI
that manages cron jobs across local, ssh, and file targets, captures every fire
into a file-backed event log under `$XDG_STATE_HOME/looper/runs/`, and emits a
stable JSON contract (`schema_version: 1`) on every command when stdout is not
a TTY. Read looper's `CLAUDE.md` and `docs/JSON_SCHEMA.md` before starting.

## Purpose

Expose looper as MCP tools/resources so MCP-compatible main agents (e.g.,
Claude) can author, observe, and operate looper's event log without shelling
out to a CLI themselves. The MCP server is the "shell" to looper's "kernel."

## Hard constraints — DO NOT VIOLATE

1. **No brain.** No LLM calls. No synthesis. No interpretation of payload
   content. The MCP server is plumbing.
2. **Connection-scoped.** Lifecycle tied to the MCP client connection. No
   always-on daemon. State (cursors, subscriptions) lives only as long as
   the connection.
3. **Compose, don't reimplement.** The MCP server never touches crontab files
   or the runs store directly. It shells out to `looper` and parses JSON.
4. **Looper's JSON contract is truth.** Respect `schema_version`. Never reshape.
5. **No transports.** No webhook/slack/email. Forwarding is the main agent's job.

## Tools to expose

1:1 CLI wrappers (low-level):

- `looper.add`, `looper.edit`, `looper.rm`, `looper.toggle`
- `looper.ls`, `looper.show`, `looper.run`
- `looper.history` (with `since`, `limit`, `format`), `looper.last`
- `looper.runs_ls` (filters), `looper.runs_show`
- `looper.publish` (once v0.3 lands)
- `looper.doctor`, `looper.apply`

Higher-level sentinel verbs (compose primitives):

- `sentinel.create({name, sources: [...], wake_schedule, wake_command, owner})`
- `sentinel.tear_down({name})`
- `sentinel.drain({name, advance_cursor})` — session-scoped cursor-aware history
- `sentinel.subscribe({name})` — filesystem-watch; pushes via MCP notifications
- `sentinel.query({name})` — reads latest synthesized output (published events)

## Resources

- `looper://runs/{run_id}` — opaque captured output for a run
- `looper://jobs/{target}/{id}` — full job definition
- `looper://history/{owner}` — owner-scoped history view

## Language & deps

- TypeScript with `@modelcontextprotocol/sdk` (or Python with the official SDK).
- Shell out to `looper` via child_process; parse JSON.
- Pin a known `schema_version` and fail loud on mismatch.

## Out of scope

- Synthesis, LLM calls, prompt opinions
- Background work that outlives the MCP connection
- Direct file I/O on crontabs or runs store
- Authn/authz (rely on OS-level isolation)

## Deliverables (first milestone)

1. Server exposing all 1:1 wrappers
2. Five `sentinel.*` verbs implemented as compositions
3. Subscribe path using filesystem-watch (chokidar or platform watcher)
4. Integration tests against sandboxed looper (use `LOOPER_SANDBOX` when shipped;
   until then, override `-f` plus state-dir env)
5. README showing a main-agent walkthrough
