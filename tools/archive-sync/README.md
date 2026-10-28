# archive-sync

Downloads new or size-changed files from the Marcer FTP into the patch layer.
It replaces the manual, interactive
[`ftp-sync`](https://github.com/slippyex/ftp-sync) workflow for automation:
headless, no key presses, no forced re-download after an idle minute, and a
machine-readable change report for the catalog pipeline.

`archive-sync` **never** modifies the root tree and **never** deletes local
files. Every run compares the current remote tree against the current local
union (root + patch). There is **no persistent comparison state**.

See [`docs/plans/PLAN-docker-pipeline.md`](../../docs/plans/PLAN-docker-pipeline.md) for the
surrounding server pipeline.

## Requirements

- Python 3.12 (the repo `.venv`; only the standard library is used)
- FTP access to the Marcer archive
- `local/paths.env` for local runs:

```sh
MARCER_ROOT_DIR="/path/to/MarcersGameDVD"
MARCER_PATCH_DIR="/path/to/MarcersGamesDVD-Update/Patch"
MARCER_FTP_HOST="host:2121"
MARCER_FTP_USER="user"
MARCER_FTP_PASS="password"
# Optional:
#MARCER_FTP_REMOTE="/GameDVD/"
#MARCER_SYNC_REPORT_DIR="/path/to/local/archive-sync"
```

`MARCER_FTP_REMOTE` defaults to `/GameDVD/`. Reports default to
`local/archive-sync/` (git-ignored); in the Docker container set
`MARCER_SYNC_REPORT_DIR=/state/archive-sync`.

## Usage

```sh
tools/archive-sync/run.sh plan          # read-only comparison, writes nothing
tools/archive-sync/run.sh sync          # download new/changed files
tools/archive-sync/run.sh status        # show the last report summary
tools/archive-sync/run.sh status --json
```

Useful options:

```sh
# Only sync one or more prefixes (repeatable / comma-separated):
tools/archive-sync/run.sh sync --only "Title Sorted" --only "Bonus"

# Skip additional names or glob patterns:
tools/archive-sync/run.sh sync --exclude "*.bak" --exclude "Dupes"

# Re-download every selected remote file, even when the size matches:
tools/archive-sync/run.sh sync --force

# Sync into a test target and write reports elsewhere:
tools/archive-sync/run.sh sync --patch /tmp/patch --report-dir /tmp/reports
```

`plan` prints the same comparison summary as `sync`, but does not create the
patch directory, download anything, or write reports.

## How changes are detected

- Remote files are compared against the **union of root and patch**. Patch
  wins when the same path exists in both layers.
- **`new`**: the remote file is missing locally → download.
- **`changed`**: the local file has a different size → download.
- **`in sync`**: the local file has the same size → no download.
- **`unknown size`**: the server did not return a size → download and verify
  the result as best as possible.
- **`local only`**: a local file is not present remotely → report only. It is
  never deleted, because the local tree may contain intentional extras. Under
  an incomplete remote directory it is not even reported.
- No previous state is used, so a first run is immediately meaningful: files
  already present locally show up as `in sync`, not as "added".
- Detection is deliberately **size-based**. Remote modification times are
  stored in the report, but are not used to trigger downloads yet.
- Same-size content changes are therefore not detected in this version.
- There is **no** ftp-sync-style "safety sync" after 60 seconds of inactivity.
- Downloads are atomic: write `<name>.part`, verify the size, set the remote
  mtime, then `os.replace` over the destination.
- Local filenames are matched case-insensitively to avoid duplicate
  case-variant files on Linux/NAS. The patch spelling wins for local matches.
- Path traversal is rejected; remote names containing `..`, absolute paths,
  NUL bytes or backslashes are skipped with a warning.
- Symlinks are not followed or downloaded.
- Directory listings run in parallel over separate FTP connections
  (`MARCER_SYNC_WORKERS`, default 4). The Marcer server is slow per directory
  (about 3-4 directories/second per connection), so parallel listing is the
  difference between minutes and hours for a full archive scan.
- If a directory cannot be listed, local-only reporting is suppressed for that
  subtree. The run finishes with exit code `1` and lists the incomplete
  directories. Downloads for the parts that could be scanned still happen.

## Reports

Default files under the report directory:

```
changes.json   machine-readable comparison of the last run
changes.txt    human-readable report
```

`changes.json` contains:

- `counts`: remote files, new, changed, in sync, unknown size, local only,
  planned downloads, downloaded, errors, warnings, incomplete directories
- `new` / `changed` / `unknown_size` / `local_only`
- `downloads` (planned) and `downloaded` (completed)
- `download_errors`, `case_conflicts`, `local_conflicts`, `warnings`
- `incomplete_dirs` (directories whose listing failed)

Because there is no state, `status` simply shows the most recent
`changes.json`. A failed download is retried automatically on the next run:
the file is still `new` or `changed` in the current comparison.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success (including "nothing to do") |
| `1` | one or more downloads failed or the remote scan was incomplete; reports were still written |
| `2` | configuration or usage error |
| `130` | interrupted with Ctrl+C |

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `MARCER_ROOT_DIR` | – | main game tree (comparison only) |
| `MARCER_PATCH_DIR` | required | patch tree / sync target |
| `MARCER_FTP_HOST` | required | `host` or `host:port` |
| `MARCER_FTP_USER` / `MARCER_FTP_PASS` | `anonymous` / empty | FTP credentials |
| `MARCER_FTP_REMOTE` | `/GameDVD/` | remote base directory |
| `MARCER_FTP_ENCODING` | `latin-1` | FTP filename encoding (use `utf-8` if the server needs it) |
| `MARCER_FTP_TIMEOUT` | `60` | socket timeout in seconds |
| `MARCER_FTP_PASSIVE` | `1` | set `0`/`false` to disable passive mode |
| `MARCER_SYNC_RETRIES` | `3` | retry count per operation |
| `MARCER_SYNC_WORKERS` | `4` | parallel FTP listing connections |
| `MARCER_SYNC_REPORT_DIR` | `local/archive-sync` | report directory |
| `MARCER_SYNC_ONLY` | – | comma-separated path prefixes |
| `MARCER_SYNC_EXCLUDES` | – | comma-separated extra exclude globs |
| `MARCER_SYNC_REPORT_LIMIT` | `0` | max list entries per section in `changes.txt` |

## Testing

```sh
.venv/bin/python -m unittest discover -s tools/archive-sync/tests -p 'test_*.py' -v
```

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
