# Crew Analysis — Top Crews in the Cracked Section

Analysis of the `Crew Sorted` and `Title Sorted` trees joined with the gameinfo
metadata (`games-cracked.json`). The goal is a **crew view** for the cracked
section: which crews and scene groups have the most release ZIPs, analogous to
the catalog sections `games`, `pd`, `utils`, `magazines` and `falcon`.

Tool: [`tools/crew-analysis`](../tools/crew-analysis/README.md). The analysis is
read-only and does not modify the game trees or the catalog artifacts.

## Data sources

| Source | Role |
|---|---|
| `Crew Sorted/Cracked Games - Crew Sorted` | canonical group names, exact ZIP basename → crew mapping |
| `Title Sorted/Cracked Games - Title Sorted` | ZIP universe (root + patch overlay) |
| `games-cracked.json` | `crew` / `cracked_by` per game folder and variant |
| `index.json` (screenshot archive) | fast merged list of the cracked Title Sorted ZIPs |

`Crew Sorted` alone is **not complete**: it contains 9,963 ZIPs, while the
cracked Title Sorted tree has 10,722 direct release ZIPs. Only 5,796 direct
ZIPs match a Crew Sorted ZIP by exact basename. The remaining releases are
attributed through `games-cracked.json` and alias/fuzzy matching.

## Method

1. **ZIP universe:** direct release ZIPs only — `Title Sorted/Cracked Games -
   Title Sorted/<letter>/<folder>/<zip>`. Subfolders such as `STX`,
   `Original`, `Demo Version`, `RAW` and `IPF` are preservation/extra variants
   and are excluded by default.
2. **Group registry:** all Crew Sorted folder names are canonical groups. Every
   `crew` and `cracked_by` label from `games-cracked.json` is added; labels not
   already known become their own group (e.g. individual crackers). Placeholders
   such as `Original` and `Unknown` are excluded.
3. **Alias normalization:** explicit aliases from
   [`tools/crew-analysis/aliases.json`](../tools/crew-analysis/aliases.json),
   plus generic rules: leading `The`, region/language suffixes (`- USA`,
   `- French`, …), abbreviation suffixes (`- MCA`, `- TCR`, …), combined-credit
   normalization (`MCA & Hotline` → `Hotline and MCA`) and a strict fuzzy
   fallback for typos.
4. **Attribution (crew view):**
   - exact ZIP basename match against Crew Sorted;
   - otherwise the matching `crew` / `cracked_by` of the folder, with **`crew`
     preferred over `cracked_by`**;
   - otherwise a global alias/fuzzy match over the registry.
5. **Joint credits** such as `Hotline and MCA`, `Replicants/Union` or
   `Lethal / Hotline` stay their own group; they are not split into their
   members.
6. **Audit:** every ZIP records its match source. Unmatched and ambiguous ZIPs
   are written to `unmatched.txt` / `ambiguous.txt`; all gameinfo labels and
   their canonical mapping are written to `groups-review.csv`.

## Runtime artifact and Crews tab

`tools/crew-analysis` writes **`crews.json`** into the `GameinfoDirectory`
(path override: `--crews-out`). It contains every canonical group plus its
per-release list (year, publisher, cracker, crew, disks, flags, TOS notes and
the ZIP rel path); the `image` field is reserved for the later
cracktro/logo curation phase. `rel` is the **full index path**
(`Title Sorted/Cracked Games - Title Sorted/...`), matching `index.json` and
`GameCard.variants[].rel`; the app also accepts legacy section-relative paths
by prefixing the discovered cracked tree.

The desktop app loads it as part of the catalog bundle:

- a new **`crews`** section/tab shows the top 24 groups by ZIP count
  (`kCrewInitialLimit`), searchable by crew name, aliases and release titles;
- a crew card uses the best available screenshot of its releases as a
  temporary image (replaced by the curated cracktro image in phase 2) and a
  group icon as fallback;
- the detail panel lists **all releases** without screenshots, with year,
  publisher, cracker/crew, language, disks, RAW/PASTI/Boxscan, TOS/Bad and the
  ZIP name;
- clicking a release opens the **existing game lightbox** pinned to that
  cracked-game card/ZIP, without leaving the Crews tab.

The full data for all 888 groups is already in `crews.json`; expanding the tab
beyond the top 24 is a UI change only.

## Current result

Generated from the local game tree (2026-10-24):

- Direct release ZIPs: **10,722**
- Assigned: **10,222**
- Unmatched: **500**
- Ambiguous exact matches: **4**
- Groups with at least one ZIP: **888**
- Match sources: exact 5,796 · gameinfo crew 2,900 · gameinfo cracker 658 ·
  alias/fuzzy 868

### Top 24

| # | Group | ZIPs |
|---:|---|---:|
| 1 | Replicants | 1129 |
| 2 | Elite | 1075 |
| 3 | Atari Legend | 822 |
| 4 | Empire | 426 |
| 5 | D-Bug | 366 |
| 6 | Blade Runners | 320 |
| 7 | International Cracking Service - ICS | 280 |
| 8 | Cynix | 276 |
| 9 | Medway Boys - TMB | 268 |
| 10 | Menacing Cracking Alliance - MCA | 230 |
| 11 | Bust | 187 |
| 12 | Klapauzius | 140 |
| 13 | Delight | 129 |
| 14 | Vmax | 126 |
| 15 | Pompey Pirates | 117 |
| 16 | Corporation - TCR | 111 |
| 17 | Hotline | 98 |
| 18 | Atariforce | 96 |
| 19 | Hotline and MCA | 90 |
| 20 | Automation | 86 |
| 21 | Vectronix | 82 |
| 22 | Boss | 80 |
| 23 | Superior | 80 |
| 24 | Revolution | 64 |

`Bust`, `Klapauzius` and `Boss` are individual crackers in the gameinfo data;
they appear because their releases have no separate crew label (the crew view
falls back to `cracked_by`). The next ranks are `Bad Brew Crew - BBC` (63),
`TEX - The Exceptions` (60), `Was Not Was` (57) and `42 Crew` (54).

Because this is a **crew view**, individual crackers whose releases are
credited to a crew (for example `Snake`, `CB`, `Cameo` or `Lethal`) do not
appear in the primary ranking. They are still part of the registry and are
visible in `groups-review.csv`; they only become primary when a release has no
matching crew label.

## Caveats

- **Counts are ZIP files, not distinct games.** Multi-disk sets and file
  versions count individually.
- **Index vs. filesystem:** by default the tool uses the merged
  `index.json` ZIP list (root + patch). `--scan` reads the `Title Sorted` tree
  directly; both should agree, but a stale index can lag behind new ZIPs.
- **Crew Sorted is a hint, not the source of truth.** It supplies canonical
  names and exact matches; the actual release count comes from the full Title
  Sorted tree and gameinfo.
- **Alias curation is ongoing.** Labels such as `Empire - USA`, `The Empire`,
  `MCA & Hotline` and `STCS` are normalized automatically or explicitly; new
  gameinfo data can add new labels. Check `groups-review.csv` and extend
  `aliases.json` / `exclude.txt` when needed.
- **Joint releases** remain separate entries by design. A release credited to
  `Hotline and MCA` counts for that combined group, not for `Hotline` and
  `MCA` individually.
- `Crew Sorted` and `Title Sorted` are local data (Marcer's archive); the tool
  does not bundle or redistribute them.

## Reproduce

```sh
tools/crew-analysis/run.sh
tools/crew-analysis/run.sh --scan --top 50
```

Outputs:

- `<GameinfoDirectory>/crews.json` — runtime crew/Release artifact consumed by
  the desktop app.
- `local/crew-analysis/` (git-ignored) — `crew-ranking.md`,
  `crew-ranking.csv`, `crew-ranking.json`, `groups-review.csv`,
  `unmatched.txt`, `ambiguous.txt`.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
