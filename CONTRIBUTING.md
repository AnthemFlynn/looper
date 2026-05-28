# Contributing to looper

## Branching model

looper uses a two-trunk model: a stable release branch and an integration branch.

```
main ───────────●──────────────────────●─────────▶   release/stable; only ever fast-forwarded from dev via a release PR
                 ╲                      ╱
dev ──●────●──────●────●────●────●─────●──────────▶   integration; every merged feature/fix lands here first
       ╲    ╲          ╲    ╲
        feat/…  fix/…    feat/…  docs/…                short-lived branches, one per change, forked from dev
```

- **`main`** — the release branch. It is **stable**: every commit on `main` has passed the full CI matrix and the milestone acceptance scripts. `main` is the GitHub default branch's *target* for releases only; it is never committed to directly.
- **`dev`** — the integration branch and the **GitHub default branch**. All feature and fix work merges here first. `dev` is where a milestone accumulates until it's complete.
- **feature / fix branches** — short-lived, one per change, **forked from `dev`** and merged back into `dev` via a pull request.

## Branch naming

| Prefix | Use |
|--------|-----|
| `feat/<slug>` | new feature |
| `fix/<slug>` | bug fix |
| `docs/<slug>` | documentation only |
| `ci/<slug>` | CI / build tooling |
| `refactor/<slug>` | internal restructuring, no behavior change |

## The flow

1. **Branch from `dev`:** `git checkout dev && git pull && git checkout -b feat/my-thing`.
2. **Build and test locally** before pushing:
   ```sh
   zig build test
   zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl   # cross-builds are first-class — check them
   ```
3. **Open a PR into `dev`.** CI runs the full matrix (native test on ubuntu + macOS, ReleaseSafe cross-build for `x86_64-linux-musl`, `aarch64-linux-musl`, `aarch64-macos`). All checks must be green before merge.
4. **Merge into `dev`** once green. Delete the feature branch.

> The `test` jobs only build native debug — they will **not** catch a cross-compile break (e.g. an opaque libc type that can't be instantiated under musl). The `build` jobs exist for exactly that. Never merge with a red `build` job.

## Releasing `dev → main`

`main` only advances when a milestone is **feature-complete and its acceptance script is green**:

1. Run the milestone acceptance gate against a release build:
   ```sh
   zig build -Doptimize=ReleaseSafe
   LOOPER_BIN="$PWD/zig-out/bin/looper" bash scripts/acceptance-v0.3.sh   # or scripts/acceptance-all.sh
   ```
2. Open a **release PR: base `main`, head `dev`.** CI runs against `main` too.
3. Merge once green. `main` now reflects a shipped, fully-validated milestone.

A milestone's acceptance script (`scripts/acceptance-vX.Y.sh`) is the contract for what "done" means — it may test commands that aren't built yet. A red acceptance section is a missing feature, not necessarily a regression; check which before treating it as a blocker.

## Commits

Conventional-commit style: `type(scope): summary`, where `type` is one of
`feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`. Keep the body
explaining the *why*. (Commit attribution trailers are disabled for this repo.)

## Code conventions

See [CLAUDE.md](CLAUDE.md) for the architectural rules the codebase holds to —
the `#looper#` marker contract, the `applyMutation` backup-before-write funnel,
the stable `--json` schema, the I/O-free `cron/` layer, and the SOLID lines that
keep backends a single switch rather than a vtable. New work should extend those
primitives rather than add parallel mechanisms.
