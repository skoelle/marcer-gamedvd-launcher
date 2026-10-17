# asset-manifest

Lists the newest Marcer GameDVD catalog-asset archives on the Marcer FTP
server and publishes a small `latest.json` **pointer** as a **GitHub Release
asset** on a fixed tag (default `catalog-latest`), so the desktop app can check
for catalog-data updates **without** touching the FTP.

The tool never uploads anything to the FTP — it only logs in, lists the asset
directory and reads the archive names (optionally hashing them). Uploading the
archives is a separate, manual step.

## What it does

1. Connect to the FTP server (`ftplib`, passive).
2. `cwd` into the asset directory and list it (`MLSD`, falling back to
   `NLST` + `SIZE`).
3. Pick the newest `screenshots-<yyyyMMdd-HHmmss>.zip` and
   `gameinfo-<yyyyMMdd-HHmmss>.zip` by the timestamp in the name.
4. Build `latest.json`.
5. (Re)upload it as a release asset on the fixed tag via the authenticated
   `gh` CLI (`gh release upload <tag> latest.json --clobber`).

The asset can be replaced as often as the archives change — the fixed tag is
**not** an app release, so this never triggers a build and stays independent of
`desktop-v*` releases.

## `latest.json`

```json
{
  "schema": 1,
  "generated_at": "2026-10-17T13:12:00Z",
  "remote": "/Uploads/MarcerGameDVDLauncher-assets/",
  "screenshots": { "archive": "screenshots-20261017-080230.zip", "size": 335544320, "sha256": "…" },
  "gameinfo":    { "archive": "gameinfo-20261017-080230.zip",    "size": 1234567,   "sha256": "…" }
}
```

`size`/`modified` come from the FTP listing; `sha256` is only added with
`--hash` (downloads the archives to hash them).

The asset URL is stable:

```
https://github.com/<owner>/<repo>/releases/download/catalog-latest/latest.json
```

## Configuration

Everything secret lives in the git-ignored `local/paths.env`:

| Variable | Meaning |
|---|---|
| `MARCER_FTP_HOST` | FTP server, `host` or `host:port` |
| `MARCER_FTP_USER` / `MARCER_FTP_PASS` | FTP credentials (empty user ⇒ `anonymous`) |
| `MARCER_FTP_ASSETS_REMOTE` | asset directory (default `/Uploads/MarcerGameDVDLauncher-assets/`) |
| `MARCER_RELEASE_TAG` | fixed release/tag holding the pointer (default `catalog-latest`) |
| `MARCER_REPO` | optional `owner/repo`; otherwise `gh` uses the current git remote |

If `MARCER_FTP_HOST` is unset, the tool falls back to
`apps/marcer_desktop/desktop.config.json` (git-ignored) or a file passed via
`--ftp-config`.

## Usage

```sh
tools/asset-manifest/run.sh                    # list FTP, (re)upload latest.json
tools/asset-manifest/run.sh --dry-run          # print latest.json, no upload
tools/asset-manifest/run.sh --create-release   # create the fixed prerelease once
tools/asset-manifest/run.sh --out latest.json
tools/asset-manifest/run.sh --hash             # include sha256 (downloads archives)
tools/asset-manifest/run.sh --only screenshots
```

First run: create the release once (prerelease so it does not take the repo's
"Latest" slot), then every later run just replaces the `latest.json` asset.
