# looper JSON contract

> This file is the source of truth for the JSON output produced by `looper`.
> It is referenced from [CLAUDE.md](../CLAUDE.md) (architectural invariants),
> [README.md](../README.md) (user-facing JSON section), and
> [ROADMAP.md](../ROADMAP.md) (v0.1 deliverable #5).

## Versioning

Every JSON document carries a top-level `schema_version` integer.

| Version | Status | Notes |
|---------|--------|-------|
| `1` | current | Introduced in v0.1 alongside JSON-first output and provenance |

**Compatibility rule.** Adding a new field to an existing object is *not* a
schema bump. Renaming a field, removing a field, or reshaping a container
*is* a schema bump. Consumers should branch on `schema_version` when they
need version-conditional logic; in practice, until v1 → v2 happens, presence
of a field is sufficient.

## When JSON is emitted

`--json` enables JSON output explicitly. **Whenever stdout is not a TTY**,
JSON output is also auto-enabled — agents piping looper to `jq`, capturing
to a file, or invoking it from another process never need to remember the
flag. Set `NO_COLOR=1` or `--no-color` to suppress ANSI on TTY output; JSON
is unaffected by either.

## Field conventions

- **Field names are `snake_case`.** No `camelCase`, no `kebab-case`.
- **Missing values are `null`.** Never `0`, never `""`, never `false` as a
  stand-in for "absent."
- **Epoch timestamps are Unix seconds (i64).** Both wall-clock fields
  (`scheduled_for`, `started_at`, `finished_at`, `created_at`,
  `last_modified_at`, `next`) and durations follow this.
- **Exit codes are signed integers.** A negative value means "killed by a
  signal or otherwise abnormal exit"; positive means the child's own exit
  status. `0` is the only success value.
- **Strings containing user data** (`command`, `target`, `human_schedule`,
  captured `stdout`/`stderr`) are JSON-escaped via `display.jsonEsc` — `"`,
  `\`, `\n`, `\r`, `\t`, control bytes are all properly encoded.
- **Multi-target output** emits one complete JSON document per target,
  separated by newlines. The `=== host ===` headers used in human mode are
  suppressed; each document carries its own `target` field for
  disambiguation.

## Document shapes

### `ls`

```json
{
  "schema_version": 1,
  "target": "file:/tmp/test.crontab",
  "jobs": [
    {
      "id": "db-backup",
      "enabled": true,
      "foreign": false,
      "target": "file:/tmp/test.crontab",
      "schedule": "0 3 * * *",
      "human_schedule": "at 03:00 every day",
      "command": "/usr/local/bin/backup.sh --db",
      "tz": "PDT",
      "tz_offset_secs": -25200,
      "tz_source": "controller_local",
      "created_by": "agent-a",
      "created_at": 1779697144,
      "last_modified_by": "agent-a",
      "last_modified_at": 1779697144,
      "next": 1779438000,
      "next_human": "2026-05-22 03:00 PDT  in 12h 27m"
    }
  ]
}
```

- `foreign` is `true` for unmanaged cron lines (no `#looper#` marker).
  Foreign jobs never have provenance fields populated.
- `tz_source` is one of `controller_local`, `target_probed`,
  `controller_fallback`.
- `next` is `null` when the schedule doesn't parse or has no next fire
  (`@reboot`); `next_human` mirrors that.
- Provenance fields are `null` for jobs added before v0.1, jobs added
  without `--as` / `LOOPER_AS`, and foreign jobs.
- Use `--owner <principal>` to filter the `jobs` array to entries whose
  `created_by` matches.

### `show <id>`

```json
{
  "schema_version": 1,
  "target": "file:/tmp/test.crontab",
  "id": "db-backup",
  "enabled": true,
  "schedule": "0 3 * * *",
  "human_schedule": "at 03:00 every day",
  "command": "/usr/local/bin/backup.sh --db",
  "tz": "PDT",
  "tz_offset_secs": -25200,
  "tz_source": "controller_local",
  "created_by": "agent-a",
  "created_at": 1779697144,
  "last_modified_by": "agent-a",
  "last_modified_at": 1779697144,
  "reboot": false,
  "next": [
    { "epoch": 1779438000, "human": "2026-05-22 03:00 PDT  in 12h 27m" },
    { "epoch": 1779524400, "human": "2026-05-23 03:00 PDT  in 1d 12h" }
  ]
}
```

- `reboot` is `true` when the schedule is `@reboot`; `next` is then `[]`.
- For unparseable schedules: `reboot: null`, `next: null`, and a
  `parse_error` field is present.

### `explain <schedule>`

```json
{
  "schema_version": 1,
  "input": "every weekday at 8am",
  "schedule": "0 8 * * 1-5",
  "human_schedule": "at 08:00 on Mon-Fri",
  "interpreted": true,
  "reboot": false,
  "tz": "PDT",
  "tz_offset_secs": -25200,
  "next": [
    { "epoch": 1779445200, "human": "2026-05-26 08:00 PDT  in 14h 27m" }
  ]
}
```

- `interpreted` is `true` when NLP rewrote the input; `false` when the
  input was already valid cron.

### `runs ls`

```json
{
  "schema_version": 1,
  "runs": [
    {
      "run_id": "db-backup-6a14a88a-97053-0",
      "status": "done",
      "source_id": "db-backup",
      "command": "/bin/sh -c '/usr/local/bin/backup.sh --db'",
      "target_label": "local",
      "once": false,
      "scheduled_for": 1779697200,
      "started_at": 1779697200,
      "finished_at": 1779697201,
      "exit_code": 0,
      "timed_out": false,
      "created_by": "agent-a"
    }
  ]
}
```

- `status` is one of `pending` (synthesized from a one-shot marker that
  hasn't fired yet), `running` (started, not finished), `done` (exit 0),
  `failed` (non-zero exit, signal kill, or timeout).
- `target_label` is the human label (`local`, `host:user@host`,
  `file:/path`), not a structured target object.
- `once` is `true` for run records from a `looper once` job.
- `created_by` is copied from the source job at run time; it survives
  edits to the underlying job.
- Filters available: `--status <s>`, `--owner <principal>`.

### `runs show <run_id>`

```json
{
  "schema_version": 1,
  "run_id": "db-backup-6a14a88a-97053-0",
  "status": "done",
  "source_id": "db-backup",
  "command": "/bin/sh -c '/usr/local/bin/backup.sh --db'",
  "target_label": "local",
  "once": false,
  "scheduled_for": 1779697200,
  "started_at": 1779697200,
  "finished_at": 1779697201,
  "exit_code": 0,
  "timed_out": false,
  "created_by": "agent-a",
  "captured": {
    "stdout": "hello\n",
    "stdout_total_bytes": 6,
    "stdout_truncated": false,
    "stderr": "",
    "stderr_total_bytes": 0,
    "stderr_truncated": false
  }
}
```

- Inline `stdout`/`stderr` are capped at 8 KiB by default; pass `--full`
  to lift the cap.
- `*_total_bytes` always reflects the full captured size on disk, even
  when `*_truncated` is `true`. The raw files live under
  `$XDG_STATE_HOME/looper/runs/<run_id>/{out,err}`.

### `runs prune`

```json
{
  "schema_version": 1,
  "kept": 12,
  "removed": ["abc-...", "def-..."]
}
```

- With `--dry-run`: adds `"dry_run": true`; `removed` lists what *would*
  be deleted without unlinking.
- With confirmation declined: adds `"aborted": true`.

### `history <id>`

```json
{
  "schema_version": 1,
  "id": "db-backup",
  "runs": [
    /* ... same record shape as `runs ls` entries ... */
  ]
}
```

- Records are filtered to those with `source_id == id`, newest-first.
- `runs: []` (with exit 0) when no records match.

### `last <id>`

```json
{
  "schema_version": 1,
  "id": "db-backup",
  "run_id": "db-backup-6a14a88a-97053-0",
  "status": "done",
  "source_id": "db-backup",
  "command": "/bin/sh -c '/usr/local/bin/backup.sh --db'",
  "target_label": "local",
  "once": false,
  "scheduled_for": 1779697200,
  "started_at": 1779697200,
  "finished_at": 1779697201,
  "exit_code": 0,
  "timed_out": false,
  "created_by": "agent-a"
}
```

- The most recent matching record is at the top level (with
  `schema_version` and `id` alongside) — agents can read `.exit_code`
  directly without indexing.
- When no records match: `{"schema_version": 1, "id": "<id>", "run": null}`
  and exit code `1`.

### `--dry-run` (any mutation)

```json
{
  "dry_run": true,
  "target": "file:/tmp/c",
  "action": "edited 'db-backup'",
  "changed": true,
  "diff": [
    { "op": "context", "line": "#looper# id=db-backup enabled=1" },
    { "op": "remove", "line": "0 3 * * * /bin/x" },
    { "op": "add", "line": "0 4 * * * /bin/x" }
  ]
}
```

- `op` is one of `context`, `remove`, `add` (from `diff.opName`).
- No-op dry-runs emit `"changed": false` with `"diff": []` so consumers
  can distinguish "nothing to do" from "errored."

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Operational error (job not found, write failed, bad schedule, no run records for `last`) |
| `2` | Usage error (unknown option, missing required value, invalid principal, conflicting flags) |
| `N` | For `looper run` and `_exec`, the child process's own exit code propagates |

## Stability promise

The shapes above are stable for `schema_version: 1`. Any breaking
change ships under a new version number. The
[`scripts/acceptance-v0.1.sh`](../scripts/acceptance-v0.1.sh) script
pins the contract executably — if it fails, the contract is broken.
