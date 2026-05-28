# PROJECT: claude-sentinels (Claude Code plugin)

Build a Claude Code plugin that bundles `looper`, `looper-mcp`, and `sentinel-kit`
into a one-install experience for agentic engineers using Claude Code.

## Purpose

After plugin install:

- `looper` binary is on PATH
- `looper-mcp` is registered as an MCP server in the user's Claude config
- `sentinel-kit` is installed (Python/TS package + `sentinel` CLI on PATH)
- Claude Code skills understand the stack and can scaffold sentinels from
  natural-language requests

## Hard constraints

1. **Packaging layer only.** No new logic. Wraps the three underlying components.
2. **Components remain à-la-carte usable.** Users who don't use Claude Code can
   still install each piece directly. The plugin must not couple them in ways
   that prevent standalone use.
3. **Skills guide, don't hide.** Skills explain patterns and produce visible
   scaffolds; they don't magic away what's happening underneath.

## Deliverables

1. Plugin manifest registering the MCP server with platform-appropriate paths
2. Setup script that:
   - Downloads the right `looper` binary for the host platform
   - Installs `sentinel-kit` from PyPI/npm
   - Writes MCP server config into `~/.claude/mcp_servers.json` (or wherever
     the current plugin spec puts it)
   - Verifies install with `looper doctor` + `sentinel run-locally`
3. Skills (each in its own `SKILL.md`):
   - `sentinel-create` — "scaffold a sentinel that watches X and reports on Y"
   - `sentinel-status` — "show me what my sentinels are doing"
   - `sentinel-debug` — "this sentinel isn't firing, walk me through it"
4. Slash commands:
   - `/sentinel-new <name>` — interactive scaffolder
   - `/sentinel-list` — registered sentinels overview
   - `/sentinel-tear-down <name>` — atomic removal of constellation
5. README with example flow: install → `/sentinel-new` → first signal received

## Out of scope

- Re-implementing functionality from the three underlying components
- Lifecycle coupling that prevents standalone use of any component
- Claude-Code-specific functionality that has no equivalent for raw users

## Build sequence note

Build `sentinel-kit` first against the bare `looper` CLI (no MCP server in the
loop). It's the more opinionated consumer; it will surface what `looper-mcp`'s
real surface needs to be. Once the kit's shape stabilizes, build `looper-mcp`
informed by what the kit needed. Wrap both in this plugin last.
