# Ideas & Backlog

Living list of planned and deferred ideas for the desktop app. This is not a
commitment; priorities can change. Implementation details live in the relevant
specs and decision records.

## On the list

- **Surface B — couch mode.** Fullscreen 10-foot UI with large
  screenshot/cover tiles, predefined filter presets and gamepad navigation
  (`gamepads`). The mode switch (config flag, CLI arg or runtime switch) is
  still undecided.
- **Hatari stage 2.** Self-hosted `hatari-latest.json` pointer with per-OS/arch
  assets and optional `sha256`, including a Linux build (AppImage or static).
  This gives stable URLs, checksums and in-app installation on Linux too.

## Deferred / not now

- **Local index / filesystem sync.** Surface ZIPs that are missing from the
  published index. Deferred because the overlay browser already covers local
  browsing and unindexed cards would be thin placeholder tiles. A lighter
  "N ZIPs not indexed" counter is also deferred. See
  [`DECISION-catalog-data-source.md`](DECISION-catalog-data-source.md) §4.
- **Pre-joined `catalog.json`.** Avoid the runtime join; deferred for now.
- **Author filter.** AtariLegend authors are shown in the detail dialog only;
  the filter bar is already crowded. Deferred.
- **Window/state persistence.** Restore the last folder/splitter positions;
  likely unnecessary. Deferred.

## Not planned / won't do

- **macOS Intel (x64) build.** Decided out; the release is Apple Silicon only.
- **Windows code signing.**
- **macOS notarization/signing.**
- **App Sandbox / Mac App Store.**
