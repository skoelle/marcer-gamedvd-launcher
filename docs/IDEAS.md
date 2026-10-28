# Ideas & Backlog

Single living list of planned, deferred and explicitly rejected ideas. This is
not a commitment; priorities can change. Implementation details live in the
relevant specs and decision records.

## On the list

- **Surface B — couch mode.** Fullscreen 10-foot UI with large
  screenshot/cover tiles, predefined filter presets and gamepad navigation
  (`gamepads`). The mode switch (config flag, CLI arg or runtime switch) is
  undecided.
- **Hatari stage 2.** Self-hosted `hatari-latest.json` pointer with per-OS/arch
  assets and optional `sha256`, including a Linux build (AppImage or static).
  This gives stable URLs, checksums and in-app installation on Linux too.
- **Prefer a system Hatari.** Detect an existing install (`/usr/bin/hatari`,
  Homebrew) and offer it before downloading.
- **Architecture-aware assets.** `hatariBuildFor` keys on the OS only; add CPU
  architecture detection if a platform gains separate builds.
- **Local index / filesystem sync.** Surface ZIPs that are missing from the
  published index. Deferred because the overlay browser already covers local
  browsing and unindexed cards would be thin placeholder tiles. A lighter
  "N ZIPs not indexed" counter is also deferred. See
  [`decisions/DECISION-catalog-data-source.md`](decisions/DECISION-catalog-data-source.md) §3.4.
- **Pre-joined `catalog.json`.** Avoid the runtime join; deferred for now.
- **Gameinfo audit reports.** Generator option for TOS/bad notes, dump gaps and
  screenshot coverage (distinct from the unmatched report).
- **AtariLegend `images.zip` processing.** Standalone large-asset import; the
  app currently hotlinks the web images.
- **AtariLegend weekly automation.** Automate fetch + cache refresh, and decide
  when the app cache is rebuilt (startup check vs manual).
- **PirateFinder alias curation.** Feed reviewed `alias-candidates.csv` entries
  into `tools/crew-analysis/aliases.json` (manual review; crackers and crews can
  share names).
- **PirateFinder metadata overlay.** Show the matched catalogue label/year/
  publisher/crew in "This ZIP" and use menu appearances for "also on …".
- **Author filter.** AtariLegend authors are shown in the detail dialog only;
  the filter bar is already crowded. Deferred.
- **Window/state persistence.** Restore the last folder/splitter positions;
  likely unnecessary. Deferred.
- **Security-scoped bookmarks.** Only needed if a sandboxed macOS build is ever
  required (Mac App Store); a substantial rework.

## Not planned / won't do

- **macOS Intel (x64) build.** Decided out; the release is Apple Silicon only.
- **Windows code signing.**
- **macOS notarization/signing.**
- **App Sandbox / Mac App Store.**
