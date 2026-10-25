/* Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
   Licensed under the MIT License. See LICENSE file in project root.
   Gallery frontend: grid, filters, lightbox, keyboard, deep links. */
"use strict";

const STATUS_OPTIONS = [
  ["with_screenshot", "with screenshot"],
  ["any", "any status"],
  ["done", "done (game)"],
  ["desktop", "desktop (only)"],
  ["desktop_any", "desktop (any ZIP)"],
  ["desktop_text", "desktop text"],
  ["desktop_black", "desktop black"],
  ["no_usable_shots", "no usable shots (only)"],
  ["no_usable_shots_any", "no usable shots (any ZIP)"],
  ["interrupted", "interrupted"],
  ["pending", "pending"],
  ["skipped_disk_n", "skipped (disk 2+)"],
];
const TRI_OPTIONS = [["any", "any"], ["yes", "yes"], ["no", "no"]];
const STATUS_LABELS = Object.fromEntries(STATUS_OPTIONS);
const LETTERS = ["0-9", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("")];
const SORT_KEYS = ["name", "year", "publisher", "cracker", "crew"];
const SECTION_INDEX_NAMES = {
  cracked: "index.json", pd: "index-pd.json", utils: "index-utils.json",
  magazine: "index-magazine.json", falcon: "index-falcon.json",
};
const SECTION_KEYS = [...Object.keys(SECTION_INDEX_NAMES), "crew"];

const SECTION_CONTROLS = {
  cracked: ["status", "publisher", "crew", "cracker", "language", "year",
            "raw", "pasti", "boxscan", "tos"],
  pd: ["status", "publisher", "language", "year", "tos"],
  utils: ["status", "publisher", "crew", "cracker", "language", "year",
          "raw", "tos"],
  magazine: ["status", "year"],
  falcon: ["status"],
};
const FACET_LABELS = {
  status: "Status", publisher: "Publisher", crew: "Crew",
  cracker: "Cracker", language: "Language", year: "Year", raw: "RAW",
  pasti: "PASTI", boxscan: "Boxscan", tos: "TOS/Bad",
};

const state = {
  section: "cracked",
  status: "with_screenshot",
  q: "",
  letter: "any",
  publisher: "any",
  crew: "any",
  cracker: "any",
  language: "any",
  year: "any",
  raw: "any",
  pasti: "any",
  boxscan: "any",
  tos: "any",
  sort: "name",
  order: "asc",
  offset: 0,
  limit: 60,
  entry: null,          // deep-link target, consumed once
};
let meta = null;
let pageCards = [];
let focusIdx = -1;
let lb = null;          // lightbox state {cards, idx, variant, img}
let searchTimer = null;
let showCands = true;       // from meta.show_candidates (config)
let defaultStatus = "with_screenshot";  // from meta.default_status (config)
const assetCache = new Map();
const assetPending = new Map();
let assetKey = null;
const crewCache = new Map();
let crewView = null;
let crewSearchTimer = null;

// Every section starts with the configured preset (usually `with_screenshot`).
const sectionDefaultStatus = () => defaultStatus;

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;");
const imgSrc = (p) => "/img/" + p.split("/").map(encodeURIComponent).join("/");
const normCrew = (s) => String(s == null ? "" : s).trim().toLowerCase()
  .replace(/\s*[&+]\s*/g, " and ").replace(/\s+/g, " ").trim();

// ---------------------------------------------------------------- state <-> URL
function readURL() {
  const u = new URLSearchParams(location.search);
  for (const key of ["section", "status", "q", "letter", "publisher",
    "crew", "cracker", "language", "year", "raw", "pasti", "boxscan", "tos",
    "sort", "order"]) {
    if (u.has(key)) state[key] = u.get(key);
  }
  if (u.has("offset")) state.offset = Math.max(0, parseInt(u.get("offset"), 10) || 0);
  if (u.has("entry")) state.entry = u.get("entry");
  if (!SECTION_KEYS.includes(state.section)) {
    state.section = "cracked";
  }
}

function writeURL(push) {
  const u = new URLSearchParams();
  const keep = (k, v, dflt) => {
    if (v != null && v !== "" && v !== dflt) u.set(k, v);
  };
  keep("section", state.section, "cracked");
  keep("q", state.q, "");
  keep("offset", state.offset ? String(state.offset) : "", "0");
  if (state.section !== "crew") {
    keep("status", state.status, sectionDefaultStatus());
    keep("letter", state.letter, "any");
    for (const k of ["publisher", "crew", "cracker", "language", "year",
      "raw", "pasti", "boxscan", "tos"]) keep(k, state[k], "any");
    keep("sort", state.sort, "name");
    keep("order", state.order, "asc");
  }
  if (lb && !lb.standalone && lb.cards[lb.idx] &&
      lb.cards[lb.idx].variants[lb.variant]) {
    u.set("entry", lb.cards[lb.idx].variants[lb.variant].rel);
  }
  const url = location.pathname + (u.toString() ? "?" + u : "");
  if (push) history.pushState(null, "", url);
  else history.replaceState(null, "", url);
}

// ---------------------------------------------------------------- API
async function api(path) {
  const res = await fetch(path);
  if (res.status === 503) {
    const err = await res.json().catch(() => ({ error: "data unavailable" }));
    throw new Error(err.error || "data unavailable");
  }
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(err.error || res.statusText);
  }
  return res.json();
}

function entriesQuery(extra) {
  const p = new URLSearchParams();
  p.set("section", state.section);
  p.set("status", state.status);
  if (state.q) p.set("q", state.q);
  if (state.letter !== "any") p.set("letter", state.letter);
  const fields = SECTION_CONTROLS[state.section] || [];
  for (const k of ["publisher", "crew", "cracker", "language", "year",
    "raw", "pasti", "boxscan", "tos"]) {
    if (fields.includes(k) && state[k] !== "any") p.set(k, state[k]);
  }
  p.set("sort", state.sort);
  p.set("order", state.order);
  p.set("offset", String(state.offset));
  p.set("limit", String(state.limit));
  if (extra) for (const [k, v] of Object.entries(extra)) p.set(k, v);
  return "/api/entries?" + p;
}

function crewsQuery() {
  const p = new URLSearchParams();
  if (state.q) p.set("q", state.q);
  p.set("offset", String(state.offset));
  p.set("limit", String(state.limit));
  return "/api/crews?" + p;
}

// ---------------------------------------------------------------- controls
function buildStatusOptions() {
  const sel = $("status");
  sel.innerHTML = STATUS_OPTIONS
    .map(([v, l]) => `<option value="${v}">${l}</option>`).join("");
  sel.value = state.status;
}

function facetOptions(id, values, anyLabel) {
  const sel = $(id);
  const cur = state[id];
  sel.innerHTML = `<option value="any">${anyLabel}</option>` +
    values.map((v) => `<option value="${esc(v)}">${esc(v)}</option>`).join("");
  sel.value = values.includes(cur) || cur === "any" ? cur : "any";
  if (sel.value !== cur) state[id] = sel.value;
}

function buildFacets() {
  const section = state.section;
  const isCrew = section === "crew";
  const facets = (meta && meta.facets && meta.facets[section]) || {};
  const fields = SECTION_CONTROLS[section] || [];
  // hide controls not available for this section / without gameinfo
  for (const id of ["status", "publisher", "crew", "cracker", "language",
    "year", "raw", "pasti", "boxscan", "tos", "sort", "clear",
    "search"]) {
    const el = $(id);
    if (!el) continue;
    if (isCrew) {
      el.hidden = id !== "search" && id !== "clear";
      continue;
    }
    if (id === "sort" || id === "clear" || id === "search") {
      el.hidden = false;
      continue;
    }
    el.hidden = !fields.includes(id);
  }
  if (isCrew) return;
  if (!meta || !meta.gameinfo) {
    for (const id of ["publisher", "crew", "cracker", "language", "year",
      "raw", "pasti", "boxscan", "tos"]) $(id).hidden = true;
  } else {
    facetOptions("publisher", facets.publishers || [], "Publisher: any");
    facetOptions("crew", facets.crews || [], "Crew: any");
    facetOptions("cracker", facets.crackers || [], "Cracker: any");
    facetOptions("language", facets.languages || [], "Language: any");
    facetOptions("year", facets.years || [], "Year: any");
  }
  for (const id of ["raw", "pasti", "boxscan"]) {
    $(id).innerHTML = TRI_OPTIONS
      .map(([v, l]) => `<option value="${v}">${id}: ${l}</option>`).join("");
    $(id).value = state[id];
  }
  $("tos").innerHTML =
    `<option value="any">TOS/Bad: any</option><option value="has">TOS/Bad: has note</option>`;
  $("tos").value = state.tos;
  $("sort").value = `${SORT_KEYS.includes(state.sort) ? state.sort : "name"}:${state.order === "desc" ? "desc" : "asc"}`;
}

function buildLetters() {
  const box = $("letters");
  if (state.section === "crew") {
    box.hidden = true;
    box.innerHTML = "";
    return;
  }
  box.hidden = false;
  const avail = new Set(((meta && meta.facets &&
    meta.facets[state.section] && meta.facets[state.section].letters) || []));
  let html = `<button data-letter="any" class="${state.letter === "any" ? "active" : ""}">Any</button>`;
  for (const l of LETTERS) {
    const on = state.letter === l;
    const dim = meta && meta.gameinfo && !avail.has(l) ? ' style="opacity:.45"' : "";
    html += `<button data-letter="${l}" class="${on ? "active" : ""}"${dim}>${l}</button>`;
  }
  box.innerHTML = html;
}

function renderStats(extra) {
  if (!meta) return;
  const section = state.section;
  if (section === "crew") {
    const crew = meta.crews || {};
    const parts = [];
    if (crew.error) {
      parts.push(`<span class="st">crew data: ${esc(crew.error)}</span>`);
    } else {
      const groups = crew.visible_groups || 0;
      const shown = crew.groups || 0;
      parts.push(`<span class="st"><b>${groups}</b> crews</span>`);
      parts.push(`<span class="st"><b>${crew.releases || 0}</b> releases</span>`);
      if (groups > shown) {
        parts.push(`<span class="st">top <b>${shown}</b> of ${groups}</span>`);
      }
      if (crew.generated_at) {
        parts.push(`<span class="st">crews: ${esc(crew.generated_at)}</span>`);
      }
    }
    if (extra) parts.push(`<span class="hint">${esc(extra)}</span>`);
    parts.push(`<span class="st app-version">gallery ${esc(meta.tool_version)}</span>`);
    $("stats").innerHTML = parts.join("");
    return;
  }
  const sec = (meta.sections && meta.sections[section]) || {};
  const sc = (meta.status_counts && meta.status_counts[section]) || {};
  const gc = (meta.game_status_counts && meta.game_status_counts[section]) || {};
  const idx = (meta.index && meta.index[section]) || {};
  const parts = [];
  if (meta.gameinfo && sec.cards != null) {
    // both counts are games (cards), like the desktop status bar
    parts.push(`<span class="st"><b>${sec.cards}</b> folders</span>`);
    parts.push(`<span class="st"><b>${sec.with_screenshot}</b> with screenshot</span>`);
  } else {
    parts.push(`<span class="st"><b>${idx.entries || 0}</b> index entries</span>`);
  }
  const order = ["done", "desktop", "desktop_any", "pending",
    "skipped_disk_n", "no_usable_shots", "no_usable_shots_any", "interrupted"];
  for (const k of order) {
    const games = gc[k] || 0;
    const zips = sc[k] || 0;
    if (k.endsWith("_any")) {
      const base = k.slice(0, -4);
      if ((gc[base] || 0) === games && (sc[base] || 0) === zips) continue;
    }
    if (!meta.gameinfo) {
      // no card join: only the ZIP level counts are known
      if (zips) parts.push(`<span class="st">${esc(STATUS_LABELS[k] || k)} <b>${zips}</b></span>`);
      continue;
    }
    if (!games && !zips) continue;
    // `done 2635 (8979 zips)` — games (ZIPs), like the desktop status bar
    parts.push(`<span class="st">${esc(STATUS_LABELS[k] || k)} <b>${games}</b> (${zips} zips)</span>`);
  }
  // gameinfo coverage (matched folders) is cracked-only (desktop parity)
  if (section === "cracked" && meta.coverage
      && meta.coverage.matched_folders != null) {
    parts.push(`<span class="st">gameinfo <b>${meta.coverage.matched_folders}</b> folders</span>`);
  }
  const noInfo = sec.no_info || 0;
  // magazine/falcon cards are index-only by design — never report missing info
  if (noInfo && section !== "magazine" && section !== "falcon") {
    parts.push(`<span class="st">${noInfo} without gameinfo</span>`);
  }
  if (extra) parts.push(`<span class="hint">${esc(extra)}</span>`);
  parts.push(`<span class="st app-version">gallery ${esc(meta.tool_version)}</span>`);
  $("stats").innerHTML = parts.join("");
}

function renderFooter() {
  if (!meta) return;
  const bits = [];
  if (state.section === "crew") {
    const crew = meta.crews || {};
    if (crew.generated_at) bits.push("crews: " + crew.generated_at);
    if (crew.error) bits.push("crew data: " + crew.error);
    $("footer").textContent = bits.join("  ·  ");
    return;
  }
  const idx = (meta.index && meta.index[state.section]) || {};
  if (idx.mtime) {
    const name = SECTION_INDEX_NAMES[state.section] || "index.json";
    bits.push(name + ": " + new Date(idx.mtime * 1000).toLocaleString());
  }
  if (meta.generated_at) bits.push("gameinfo: " + meta.generated_at);
  // the tool version is shown right-aligned in the statistics bar
  if (!meta.gameinfo) bits.push("gameinfo unavailable — screenshots only");
  $("footer").textContent = bits.join("  ·  ");
}

function showBanner(msg, retry) {
  const b = $("banner");
  b.hidden = false;
  b.innerHTML = `<span>${esc(msg)}</span>` +
    (retry ? ` <button type="button" id="banner-retry">Retry</button>` : "");
  if (retry) $("banner-retry").onclick = retry;
}
function hideBanner() { $("banner").hidden = true; }

// ---------------------------------------------------------------- grid
function isCrewCard(card) {
  return !!(card && card.crew);
}

function badgeFor(card) {
  if (!card.display_status) {
    return `<span class="badge b-other">meta</span>`;
  }
  if (card.display_status === "done") {
    return `<span class="badge b-game">game</span>`;
  }
  if (card.display_status === "desktop") {
    return `<span class="badge b-desktop">desktop</span>`;
  }
  return `<span class="badge b-failed">${esc(card.display_status)}</span>`;
}

function renderGrid(cards) {
  pageCards = cards;
  focusIdx = -1;
  const grid = $("grid");
  if (!cards.length) {
    grid.innerHTML = "";
    $("empty").hidden = false;
    $("pager").hidden = true;
    return;
  }
  $("empty").hidden = true;
  grid.innerHTML = cards.map((c, i) => {
    if (isCrewCard(c)) {
      const kind = c.kind === "cracker" ? "cracker" : "crew";
      const preview = c.preview
        ? `<img loading="lazy" src="${imgSrc(c.preview)}" alt="">`
        : `<div class="ph crew-ph">CREW</div>`;
      return `<div class="card crew-card" data-idx="${i}" data-v="0" tabindex="-1">` +
        `<span class="badge ${kind === "cracker" ? "b-cracker" : "b-crew"}">${kind}</span>` +
        `<span class="chip">${c.zips} ZIPs</span>` +
        `<div class="name">${esc(c.name)}</div>` +
        `<div class="crew-release-count">${c.releases} releases</div>${preview}</div>`;
    }
    const nzip = c.variants.length;
    const chip = nzip > 1 ? `<span class="chip">×${nzip}</span>` : "";
    const layer = c.layer ? `<span class="layer">${esc(c.layer)}</span>` : "";
    const tos = cardTos(c) ? `<span class="chip chip-tos">TOS ${esc(cardTos(c))}</span>` : "";
    const preferred = preferredPreview(c);
    const fv = (c.focus_variant != null && c.focus_variant >= 0)
      ? c.focus_variant : preferred.idx;
    const focusActive = c.focus_variant != null;
    let body;
    if (c.focus_variant === -1) {
      // crew/cracker focus with no matching ZIP: hint + up to 4 other shots
      const missLabel = state.cracker !== "any"
        ? "no cracker ZIP — other variants" : "no crew ZIP — other variants";
      const thumbs = variantThumbs(c);
      body = thumbs
        ? `<div class="var-miss">${missLabel}</div>` +
          `<div class="var-thumbs">${thumbs}</div>`
        : `<div class="ph"></div>`;
    } else if (!focusActive && countPreviews(c) >= 2 &&
        (statusPreviewActive() || doneThumbCount(c) !== 1)) {
      // no focus: show up to 4 variant screenshots (best first). With a
      // concrete status filter the selected status is first and the
      // single-done exception does not apply; otherwise exactly one game
      // shot shows the large preview instead (desktop `_multiThumbBody`).
      body = `<div class="var-thumbs">${variantThumbs(c)}</div>`;
    } else if (preferred.preview) {
      body = `<img loading="lazy" src="${imgSrc(preferred.preview)}" alt="">`;
      if (showCands) {
        // Candidates of the variant whose preview is shown (not just the
        // first ZIP) so multi-variant cards keep the done/game subimages.
        const src = c.variants[fv] || c.variants[0] || {};
        const cands = src.candidates || [];
        if (cands.length && !focusActive) {
          body += `<div class="cands">` +
            cands.map((p) => `<img loading="lazy" src="${imgSrc(p)}" alt="" data-cand="${i}">`).join("") +
            `</div>`;
        }
      }
    } else {
      body = `<div class="ph"></div>`;
    }
    return `<div class="card" data-idx="${i}" data-v="${fv}" tabindex="-1">` +
      `${badgeFor(c)}${chip}${layer}${tos}` +
      `<div class="name">${esc(c.name)}</div>${body}</div>`;
  }).join("");
  $("pager").hidden = false;
}

// count variants that have a screenshot
function countPreviews(card) {
  return card.variants.reduce((n, vv) => n + (vv.preview ? 1 : 0), 0);
}

// Non-default TOS version the screenshot generator needed for this card
// (first variant that carries one, e.g. "1.02"); null/"" for the default TOS
// (`SPEC-screenshot-generator.md` §7.5, desktop `GameCard.tosVersion`).
function cardTos(card) {
  for (const vv of card.variants || []) {
    if (vv.tos) return vv.tos;
  }
  return null;
}

// Variant indices shown as clickable thumbs, best first: status tier
// (`done`, then `desktop`, then the rest), then `kind: game` before other
// kinds, then variant index — desktop `GameCard.thumbIndices` (the plain
// gallery only ranked by status). At most `limit` entries.
const STATUS_RANK = { done: 0, desktop: 1 };

// Concrete status filters show the selected ZIP status first. `null` keeps
// the done-first default used by with screenshot / any / done.
function preferredStatusInfo() {
  if (state.crew !== "any" || state.cracker !== "any") return null;
  switch (state.status) {
    case "desktop":
    case "desktop_any":
      return { status: "desktop" };
    case "desktop_text":
      return { status: "desktop", kind: "textscreen" };
    case "desktop_black":
      return { status: "desktop", kind: "darkscreen" };
    case "no_usable_shots":
    case "no_usable_shots_any":
      return { status: "no_usable_shots" };
    case "pending":
    case "interrupted":
    case "skipped_disk_n":
      return { status: state.status };
    default:
      return null;
  }
}

function statusPreviewActive() {
  return preferredStatusInfo() !== null;
}

function preferredPreview(card) {
  const pref = preferredStatusInfo();
  const fallback = Math.max(
    0, card.variants.findIndex((vv) => vv.preview === card.preview));
  if (!pref) {
    return { idx: fallback, preview: card.preview };
  }
  let idx = card.variants.findIndex((vv) =>
    vv.status === pref.status &&
    (!pref.kind || vv.kind === pref.kind) && vv.preview);
  if (idx < 0 && pref.kind) {
    idx = card.variants.findIndex((vv) =>
      vv.status === pref.status && vv.preview);
  }
  if (idx < 0) idx = fallback;
  return {
    idx,
    preview: idx >= 0 ? (card.variants[idx].preview || card.preview) : card.preview,
  };
}

function thumbVariantIndices(card, limit = 4) {
  const pref = preferredStatusInfo();
  const preferredRank = (vv) => {
    if (!pref) return 0;
    if (vv.status !== pref.status) return 2;
    return !pref.kind || vv.kind === pref.kind ? 0 : 1;
  };
  return card.variants
    .map((vv, vi) => ({ vv, vi }))
    .filter((x) => x.vv.preview)
    .sort((a, b) => preferredRank(a.vv) - preferredRank(b.vv)
      || (STATUS_RANK[a.vv.status] ?? 2) - (STATUS_RANK[b.vv.status] ?? 2)
      || (a.vv.kind === "game" ? 0 : 1) - (b.vv.kind === "game" ? 0 : 1)
      || a.vi - b.vi)
    .slice(0, limit)
    .map((x) => x.vi);
}

// Number of shown thumbs that are real game screenshots (status `done`);
// the rest are e.g. `desktop` shots (desktop `_doneThumbCount`).
function doneThumbCount(card) {
  return thumbVariantIndices(card)
    .filter((vi) => card.variants[vi].status === "done").length;
}

// up to 4 clickable variant screenshots, "best" first
function variantThumbs(card) {
  return thumbVariantIndices(card).map((vi) => {
    const vv = card.variants[vi];
    return `<img loading="lazy" src="${imgSrc(vv.preview)}" alt="" ` +
      `data-varv="${vi}" title="${esc(vv.name)} (${esc(vv.status)})">`;
  }).join("");
}

function renderPager(total) {
  const pages = Math.max(1, Math.ceil(total / state.limit));
  const page = Math.floor(state.offset / state.limit) + 1;
  $("page-info").textContent = `page ${page} / ${pages}  ·  ${total} entries`;
  $("page-prev").disabled = state.offset === 0;
  $("page-next").disabled = state.offset + state.limit >= total;
}

async function loadEntries() {
  try {
    hideBanner();
    if (lb) { lb = null; $("lightbox").hidden = true; }
    if (crewView) closeCrewBrowser(false);
    if (state.section === "crew") {
      const data = await api(crewsQuery());
      renderGrid(data.cards);
      renderPager(data.total);
      $("result-count").textContent = `${data.total} crew${data.total === 1 ? "" : "s"}`;
      writeURL(false);
      renderStats();
      renderFooter();
      return;
    }
    const data = await api(entriesQuery());
    renderGrid(data.cards);
    renderPager(data.total);
    $("result-count").textContent = `${data.total} results`;
    writeURL(false);
    renderStats();
    renderFooter();
  } catch (err) {
    showBanner(err.message, () => loadEntries());
    $("grid").innerHTML = "";
    $("pager").hidden = true;
  }
}

// ---------------------------------------------------------------- hover panel
// The info panel is a mouse affordance only: touch/mobile devices synthesize
// mouseover on tap, so without this guard the panel would pop up ~400 ms
// after every tap and could stick (SPEC 6.x — no hover info on touch).
const hoverMedia = window.matchMedia("(hover: hover) and (pointer: fine)");
const canHover = () => hoverMedia.matches;
let hoverTimer = null;
function hoverHTML(card) {
  const rows = [];
  const add = (k, v) => {
    if (v !== "" && v != null && v !== false) rows.push(
      `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`);
  };
  if (isCrewCard(card)) {
    add("Kind", card.kind === "cracker" ? "individual cracker" : "crew");
    add("ZIPs", card.zips);
    add("Releases", card.releases);
    add("Aliases", (card.aliases || []).join(", "));
  } else if (card.info) {
    const i = card.info;
    add("Title", i.title);
    add("Publisher", i.publisher);
    add("Cracked by", i.cracked_by);
    add("Crew", i.crew);
    add("Intro", i.intro_code);
    add("Language", i.language);
    add("Year", i.release);
    add("Disks", i.disks);
    add("Version", i.version);
    add("Company", i.company);
    add("Licence", i.licence);
    add("Special", i.special_flag);
    add("Note", i.special_note);
    add("TOS/Bad", i.tos_bad);
    const flags = [];
    if (i.raw_dump) flags.push("RAW");
    if (i.pasti_dump) flags.push("PASTI");
    if (i.boxscan) flags.push("Boxscan");
    add("Flags", flags.join(", "));
    add("Variants", card.variants.length > 1
      ? `${card.variants.length} ZIPs` : "");
  } else {
    add("Path", card.variants[0] ? card.variants[0].rel : card.id);
    add("Status", card.display_status);
    add("Layer", card.layer);
    const size = card.variants[0] && card.variants[0].size;
    if (size) add("Size", (size / 1024).toFixed(0) + " KB");
  }
  return `<div class="hp-title">${esc(card.name)}</div>` +
    `<table>${rows.join("")}</table>`;
}

function showHover(card, el) {
  const panel = $("hover");
  panel.innerHTML = hoverHTML(card);
  panel.hidden = false;
  const r = el.getBoundingClientRect();
  const pr = panel.getBoundingClientRect();
  let x = r.right + 10;
  let y = r.top;
  if (x + pr.width > window.innerWidth - 8) x = Math.max(8, r.left - pr.width - 10);
  if (y + pr.height > window.innerHeight - 8) y = Math.max(8, window.innerHeight - pr.height - 8);
  panel.style.left = x + "px";
  panel.style.top = y + "px";
}
function hideHover() {
  clearTimeout(hoverTimer);
  $("hover").hidden = true;
}

// ---------------------------------------------------------------- lightbox
function openLightbox(idx, variant, img) {
  if (idx < 0 || idx >= pageCards.length) return;
  lb = {
    cards: pageCards, idx, variant: variant || 0, img: img || 0,
    section: state.section, standalone: false,
  };
  $("lightbox").hidden = false;
  renderLightbox();
  writeURL(true);
}

function openStandaloneLightbox(card, variant) {
  lb = {
    cards: [card], idx: 0, variant: variant || 0, img: 0,
    section: "cracked", standalone: true,
  };
  assetKey = null;
  $("lightbox").hidden = false;
  renderLightbox();
}

function closeLightbox() {
  const wasStandalone = !!(lb && lb.standalone);
  lb = null;
  assetKey = null;
  $("lightbox").hidden = true;
  if (!wasStandalone) writeURL(false);
  if (wasStandalone && crewView) {
    const card = $("crew-grid").querySelector(
      `.crew-release[data-idx="${crewView.selected}"]`);
    if (card) card.focus();
    else $("crew-grid").focus();
    return;
  }
  const card = $("grid").querySelector(`.card[data-idx="${focusIdx}"]`);
  if (card) card.focus();
}

function lightboxImages(card) {
  const v = card.variants[lb.variant];
  if (!v) return [];
  const imgs = [];
  if (v.preview) imgs.push(v.preview);
  for (const c of (v.candidates || [])) imgs.push(c);
  return imgs;
}

// Filmstrip display order: ZIPs directly in the game folder always before
// ZIPs from subfolders (`Original/`, `STX/`, …); within the same depth ones
// with a screenshot first (stable) — desktop `_variants`
// (game_lightbox.dart). `lb.variant` keeps the ORIGINAL variant index (used
// for the URL and the side panel); only the rendered order and ↑/↓
// navigation follow this.
function filmOrder(card) {
  return card.variants
    .map((vv, vi) => ({
      vi,
      depth: String(vv.rel || "").split("/").length,
      noPreview: vv.preview ? 0 : 1,
    }))
    .sort((a, b) =>
      a.depth - b.depth || a.noPreview - b.noPreview || a.vi - b.vi)
    .map((x) => x.vi);
}

// ↑/↓: move to the previous/next variant in filmstrip display order
function lbMoveVariant(delta) {
  const card = lb.cards[lb.idx];
  if (!card || card.variants.length < 2) return;
  const order = filmOrder(card);
  let pos = order.indexOf(lb.variant);
  if (pos < 0) pos = 0;
  lb.variant = order[(pos + delta + order.length) % order.length];
  lb.img = 0;
  renderLightbox();
  writeURL(false);
}

const CREW_STOPWORDS = new Set(["and", "the", "co", "crew", "inc", "ltd",
  "team", "software"]);

function crewTokens(s) {
  return (String(s == null ? "" : s).toLowerCase().match(/[a-z0-9]+/g) || [])
    .filter((t) => !CREW_STOPWORDS.has(t) && t.length >= 2);
}

function firstWithPreview(card, idxs) {
  for (const i of idxs) if (card.variants[i].preview) return i;
  return idxs.length ? idxs[0] : -1;
}

// Client-side port of the server `_focus_variant` / desktop
// `focusVariant` fuzzy matcher: index of the ZIP variant that belongs to
// the crew/cracker group `value`, or -1 (no matching ZIP).
function lbGroupVariant(card, value, kind) {
  const valueN = normCrew(value);
  if (!valueN) return -1;
  const variants = card.variants;
  // 1) normalized substring match (`&`/`+` == "and")
  const subs = variants
    .map((vv, vi) => (normCrew(vv.name).includes(valueN) ? vi : -1))
    .filter((vi) => vi >= 0);
  if (subs.length) return firstWithPreview(card, subs);
  // 2) (crew only) gameinfo variant with this crew → its cracker in names
  if (kind === "crew") {
    for (const iv of ((card.info && card.info.variants) || [])) {
      if (normCrew(iv.crew) !== valueN) continue;
      const cracker = String(iv.cracked_by == null ? "" : iv.cracked_by)
        .trim().toLowerCase();
      if (!cracker) continue;
      const hits = variants
        .map((vv, vi) => ((vv.name || "").toLowerCase().includes(cracker)
          ? vi : -1))
        .filter((vi) => vi >= 0);
      if (hits.length) return firstWithPreview(card, hits);
    }
  }
  // 3) token subset match (typo / missing connective tolerant)
  const ct = crewTokens(value);
  if (ct.length && ct.some((t) => t.length >= 3)) {
    const hits = variants
      .map((vv, vi) => {
        const nt = new Set((vv.name || "").toLowerCase()
          .match(/[a-z0-9]+/g) || []);
        return ct.every((t) => nt.has(t)) ? vi : -1;
      })
      .filter((vi) => vi >= 0);
    if (hits.length) return firstWithPreview(card, hits);
  }
  return -1;
}

// Click on a crew/cracker group in the side panel: switch to that group's
// variant of the current card; no matching ZIP ("not found") → variant 0
// (desktop `onSelectGroup`).
function lbSelectGroup(value, kind) {
  if (!lb) return;
  const card = lb.cards[lb.idx];
  if (!card) return;
  const target = lbGroupVariant(card, value, kind);
  lb.variant = target >= 0 ? target : 0;
  lb.img = 0;
  renderLightbox();
  writeURL(false);
}

// Integer-only upscale of the lightbox main image (pixel-art safe). Only
// applied when the image fits or can be upscaled (scale >= 1); when it is
// larger than the available area on either axis we clear the explicit size
// and let CSS (`max-width`/`max-height: 100%` + `object-fit: contain`)
// downscale proportionally — writing an explicit width AND height there
// would let the browser clamp each axis independently and squash the
// screenshot to a thin strip (SPEC-gallery-webapp.md 6.5).
function fitIntegerScale(img) {
  if (!img || !img.naturalWidth) return;
  const wrap = img.parentElement;
  if (!wrap) return;
  const availW = wrap.clientWidth;
  const availH = wrap.clientHeight;
  if (!availW || !availH) return;
  const scale = Math.floor(Math.min(
    availW / img.naturalWidth,
    availH / img.naturalHeight
  ));
  if (scale >= 1) {
    img.style.width = (img.naturalWidth * scale) + "px";
    img.style.height = (img.naturalHeight * scale) + "px";
  } else {
    img.style.width = "";
    img.style.height = "";
  }
}

function manualVariantLabel(variant) {
  if (variant.kind === "pdf") return `${variant.label} (PDF)`;
  if (variant.kind === "document") return `${variant.label} (${variant.format})`;
  if (variant.kind === "imagePages") {
    return `${variant.label}: ${variant.file_count} ${variant.format}`;
  }
  if (variant.kind === "diskImage") return `${variant.label} (${variant.format})`;
  return variant.label;
}

function localAssetsHtml(data) {
  const box = data && data.boxscans;
  const manuals = data && data.manuals;
  const rows = [];
  if (box && box.edition_count) {
    rows.push(`<tr><td>Box scans</td><td>${box.edition_count} ` +
      `edition${box.edition_count === 1 ? "" : "s"}, ${box.image_count} ` +
      `image${box.image_count === 1 ? "" : "s"}</td></tr>`);
  }
  if (manuals && manuals.title_count) {
    rows.push(`<tr><td>Manuals</td><td>${manuals.title_count} ` +
      `title${manuals.title_count === 1 ? "" : "s"}, ${manuals.file_count} ` +
      `file${manuals.file_count === 1 ? "" : "s"}</td></tr>`);
  }
  if (!rows.length) return "";
  let html = `<h3>Local assets</h3><table>${rows.join("")}</table>`;
  if (box && box.edition_count) {
    html += `<ul class="asset-list">` +
      box.editions.map((edition) =>
        `<li>${esc(edition.label)} (${edition.image_count})</li>`).join("") +
      `</ul>`;
  }
  if (manuals && manuals.title_count) {
    html += `<ul class="asset-list">` +
      manuals.items.map((item) => {
        const variants = (item.variants || [])
          .map(manualVariantLabel).join(", ");
        return `<li>${esc(item.label)} — ${esc(variants)}</li>`;
      }).join("") +
      `</ul>`;
  }
  return html;
}

function updateLocalAssets(card) {
  const section = (lb && lb.section) || state.section;
  const key = `${section}:${card.id}`;
  assetKey = key;
  const target = $("lb-assets");
  if (!target) return;
  if (meta && meta.local_assets === false) {
    target.innerHTML = "";
    return;
  }
  if (assetCache.has(key)) {
    target.innerHTML = localAssetsHtml(assetCache.get(key));
    return;
  }
  target.innerHTML = "";
  let pending = assetPending.get(key);
  if (!pending) {
    const query = `section=${encodeURIComponent(section)}` +
      `&id=${encodeURIComponent(card.id)}`;
    pending = api("/api/local-assets?" + query)
      .then((data) => {
        assetCache.set(key, data);
        return data;
      })
      .catch(() => null)
      .finally(() => assetPending.delete(key));
    assetPending.set(key, pending);
  }
  pending.then((data) => {
    if (!data || !lb || assetKey !== key) return;
    const current = $("lb-assets");
    if (current) current.innerHTML = localAssetsHtml(data);
  });
}

function renderLightbox() {
  if (!lb) return;
  const card = lb.cards[lb.idx];
  if (!card) return closeLightbox();
  lb.variant = Math.min(lb.variant, Math.max(0, card.variants.length - 1));

  $("lb-badge").innerHTML = badgeFor(card);
  $("lb-title").textContent = card.name;
  const v = card.variants[lb.variant];
  const missPrefix = !lb.standalone && card.focus_variant === -1
    ? (state.cracker !== "any" ? "cracker ZIP not found — "
      : "crew ZIP not found — ") : "";
  $("lb-sub").textContent = v
    ? `${missPrefix}${v.status}${v.layer ? " · " + v.layer : ""}${v.size ? " · " + Math.round(v.size / 1024) + " KB" : ""}`
    : `${missPrefix}no ZIP variants`;
  // header badge row: layer, status histogram (`2× done 1× pending`), year
  // (desktop `_header`; the FAVORITE badge has no gallery counterpart)
  const badgeRow = [];
  if (card.layer) badgeRow.push(`<span class="badge b-layer">${esc(card.layer)}</span>`);
  if (v && v.tos) badgeRow.push(`<span class="badge b-tos">TOS ${esc(v.tos)}</span>`);
  const hist = Object.entries(card.status_counts || {})
    .map(([k, n]) => `${n}× ${k}`).join("  ");
  if (hist) badgeRow.push(`<span class="badge b-hist">${esc(hist)}</span>`);
  if (card.year && card.year !== "unknown") {
    badgeRow.push(`<span class="badge b-year">${esc(card.year)}</span>`);
  }
  $("lb-badges").innerHTML = badgeRow.join("");

  const pos = `${lb.idx + 1} / ${lb.cards.length}`;
  const standalone = !!lb.standalone;
  $("lb-prev").hidden = standalone;
  $("lb-next").hidden = standalone;
  // the variant counter shows the FILMSTRIP position (screenshot variants
  // first), not the raw variant index
  const order = filmOrder(card);
  const vpos = order.indexOf(lb.variant);
  $("lb-pos").textContent = card.variants.length > 1
    ? `${pos}  ·  variant ${vpos >= 0 ? vpos + 1 : lb.variant + 1} / ${card.variants.length}`
    : pos;

  const imgs = lightboxImages(card);
  lb.img = Math.min(lb.img, Math.max(0, imgs.length - 1));
  if (imgs.length) {
    const lbImg = $("lb-image");
    lbImg.onload = () => fitIntegerScale(lbImg);
    lbImg.src = imgSrc(imgs[lb.img]);
    lbImg.hidden = false;
    $("lb-ph").hidden = true;
    if (lbImg.complete && lbImg.naturalWidth) fitIntegerScale(lbImg);
  } else {
    $("lb-image").hidden = true;
    $("lb-image").removeAttribute("src");
    $("lb-ph").hidden = false;
  }

  // filmstrip: one thumb per variant in filmstrip display order (hover
  // shows the full ZIP name via title); data-v keeps the original index
  $("lb-film").innerHTML = order.map((i) => {
    const vv = card.variants[i];
    const thumb = vv.preview
      ? `<img src="${imgSrc(vv.preview)}" alt="" loading="lazy">`
      : `<div class="ph-thumb">–</div>`;
    const st = vv.preview ? `st-${vv.status === "done" ? "done" : "desktop"}` : "st-empty";
    const short = vv.name.replace(/\.zip$/i, "").replace(/^[^-]*-\s*/, "");
    const nCand = (vv.candidates || []).length;
    const badge = nCand > 1 ? `<span class="cand-count">+${nCand}</span>` : "";
    return `<button type="button" class="lb-film-item ${st} ${i === lb.variant ? "active" : ""}" data-v="${i}" title="${esc(vv.name)} (${esc(vv.status)})">${thumb}${badge}<span class="film-name">${esc(short)}</span></button>`;
  }).join("");
  const activeFilm = $("lb-film").querySelector(".lb-film-item.active");
  if (activeFilm) activeFilm.scrollIntoView({ block: "nearest", inline: "nearest" });

  // candidate strip
  const cands = v ? (v.candidates || []) : [];
  $("lb-cands").innerHTML = cands.map((p, i) =>
    `<img src="${imgSrc(p)}" alt="" data-img="${i + (v && v.preview ? 1 : 0)}" class="${(v && v.preview ? i + 1 : i) === lb.img ? "active" : ""}">`
  ).join("");

  // side panel: metadata
  const side = $("lb-side");
  if (card.info) {
    const i = card.info;
    const rows = [];
    // `group` makes the value clickable: it jumps to that crew's/cracker's
    // variant of this card (desktop `onSelectGroup`)
    const add = (k, val, group) => {
      if (val !== "" && val != null && val !== false) {
        const cell = group
          ? `<a class="lb-link" href="#" data-group="${group}" data-group-val="${esc(val)}">${esc(val)}</a>`
          : esc(val);
        rows.push(`<tr><td>${esc(k)}</td><td>${cell}</td></tr>`);
      }
    };
    add("Title", i.title);
    add("Publisher", i.publisher);
    add("Cracked by", i.cracked_by, "cracker");
    add("Crew", i.crew, "crew");
    add("Intro code", i.intro_code);
    add("Language", i.language);
    add("Release", i.release);
    add("Disks", i.disks);
    add("Version", i.version);
    add("Company", i.company);
    add("Licence", i.licence);
    add("Special", i.special_flag);
    add("Note", i.special_note);
    add("TOS/Bad", i.tos_bad);
    const flags = [];
    if (i.raw_dump) flags.push("RAW dump");
    if (i.pasti_dump) flags.push("PASTI dump");
    if (i.boxscan) flags.push("Boxscan");
    add("Flags", flags.join(", "));
    let html = `<div id="lb-assets"></div>` +
      `<h3>Game info</h3><table>${rows.join("")}</table>`;
    if (v) {
      html += `<h3>This ZIP</h3><table>` +
        `<tr><td>File</td><td>${esc(v.name)}</td></tr>` +
        `<tr><td>Status</td><td>${esc(v.status)}</td></tr>` +
        `<tr><td>Kind</td><td>${esc(v.kind || "—")}</td></tr>` +
        (v.tos ? `<tr><td>TOS</td><td>${esc(v.tos)}</td></tr>` : "") +
        (v.layer ? `<tr><td>Layer</td><td>${esc(v.layer)}</td></tr>` : "") +
        (v.size ? `<tr><td>Size</td><td>${(v.size / 1024).toFixed(0)} KB</td></tr>` : "") +
        `<tr><td>Path</td><td>${esc(v.rel)}</td></tr></table>`;
    }
    if (i.variants && i.variants.length > 1) {
      // mark the gameinfo variant that matches the currently selected ZIP
      let selIdx = -1;
      if (v) {
        const zl = (v.name || "").toLowerCase();
        selIdx = i.variants.findIndex((rv) => {
          const cr = (rv.cracked_by || "").trim().toLowerCase();
          const crw = (rv.crew || "").trim().toLowerCase();
          return (cr && zl.includes(cr)) || (crw && zl.includes(crw));
        });
      }
      // no ZIP matched (crew/cracker focus): mark the group's variant
      if (selIdx === -1 && state.cracker !== "any") {
        selIdx = i.variants.findIndex((rv) =>
          normCrew(rv.cracked_by) === normCrew(state.cracker));
      }
      if (selIdx === -1 && state.crew !== "any") {
        selIdx = i.variants.findIndex((rv) =>
          normCrew(rv.crew) === normCrew(state.crew));
      }
      html += `<h3>Release variants (${i.variants.length})</h3>` +
        `<table class="variants-table"><tr>` +
        `<th>Title</th><th>Cracker</th><th>Crew</th><th>Year</th></tr>` +
        i.variants.map((rv, ri) => {
          // clicking the row jumps to that group's ZIP: crew first, else
          // cracker (desktop `_variantRow` + `onSelectGroup`)
          const group = rv.crew ? "crew" : (rv.cracked_by ? "cracker" : "");
          const gval = rv.crew || rv.cracked_by || "";
          const title = group
            ? `<a class="lb-link" href="#" data-group="${group}" data-group-val="${esc(gval)}">${esc(rv.title)}</a>`
            : esc(rv.title);
          return `<tr class="${ri === selIdx ? "selected " : ""}clickable">` +
            `<td>${title}</td><td>${esc(rv.cracked_by)}</td>` +
            `<td>${esc(rv.crew)}</td><td>${esc(rv.release)}</td></tr>`;
        }).join("") +
        `</table>`;
    }
    side.innerHTML = html;
  } else {
    let html = `<div id="lb-assets"></div><h3>No game info</h3>`;
    if (v) {
      html += `<table><tr><td>File</td><td>${esc(v.name)}</td></tr>` +
        `<tr><td>Status</td><td>${esc(v.status)}</td></tr>` +
        `<tr><td>Kind</td><td>${esc(v.kind || "—")}</td></tr>` +
        (v.tos ? `<tr><td>TOS</td><td>${esc(v.tos)}</td></tr>` : "") +
        (v.layer ? `<tr><td>Layer</td><td>${esc(v.layer)}</td></tr>` : "") +
        `<tr><td>Path</td><td>${esc(v.rel)}</td></tr></table>`;
    }
    side.innerHTML = html;
  }
  updateLocalAssets(card);
}

function crewSearchText(release) {
  return [
    release.title, release.folder, release.zip, release.year,
    release.publisher, release.cracked_by, release.crew, release.language,
    release.special_flag, release.special_note,
  ].filter(Boolean).join(" ").toLowerCase();
}

function crewApplyFilter() {
  if (!crewView) return [];
  const query = crewView.query.trim().toLowerCase();
  const list = crewView.releases.filter((release) =>
    !query || crewSearchText(release).includes(query));
  if (crewView.sort === "year_desc") {
    list.sort((a, b) => {
      const ay = parseInt(a.year, 10);
      const by = parseInt(b.year, 10);
      if (Number.isNaN(ay) && Number.isNaN(by)) return crewTitleCompare(a, b);
      if (Number.isNaN(ay)) return 1;
      if (Number.isNaN(by)) return -1;
      return by - ay || crewTitleCompare(a, b);
    });
  } else if (crewView.sort === "title_asc") {
    list.sort(crewTitleCompare);
  } else {
    list.sort((a, b) => {
      const ay = parseInt(a.year, 10);
      const by = parseInt(b.year, 10);
      if (Number.isNaN(ay) && Number.isNaN(by)) return crewTitleCompare(a, b);
      if (Number.isNaN(ay)) return 1;
      if (Number.isNaN(by)) return -1;
      return ay - by || crewTitleCompare(a, b);
    });
  }
  return list;
}

function crewTitleCompare(a, b) {
  const at = (a.title || a.folder || a.zip || a.rel).toLowerCase();
  const bt = (b.title || b.folder || b.zip || b.rel).toLowerCase();
  return at.localeCompare(bt) ||
    (a.zip || a.rel).toLowerCase().localeCompare((b.zip || b.rel).toLowerCase());
}

function crewColumns() {
  const grid = $("crew-grid");
  const card = grid.querySelector(".crew-release");
  if (!card) return 1;
  const style = getComputedStyle(grid);
  const gap = parseFloat(style.columnGap || style.gap) || 8;
  const width = card.getBoundingClientRect().width + gap;
  return Math.max(1, Math.round(grid.clientWidth / width));
}

function crewPageSize() {
  const grid = $("crew-grid");
  const card = grid.querySelector(".crew-release");
  const cols = crewColumns();
  if (!card) return cols;
  const style = getComputedStyle(grid);
  const gap = parseFloat(style.rowGap || style.gap) || 8;
  const height = card.getBoundingClientRect().height + gap;
  const rows = Math.max(1, Math.floor(grid.clientHeight / height));
  return rows * cols;
}

function crewRenderGrid() {
  const grid = $("crew-grid");
  if (!crewView || !crewView.filtered.length) {
    grid.innerHTML = `<div class="crew-empty">No releases match the filter.</div>`;
    return;
  }
  grid.innerHTML = crewView.filtered.map((release, index) => {
    const preview = release.preview
      ? `<img loading="lazy" src="${imgSrc(release.preview)}" alt="">`
      : `<div class="crew-thumb-ph">NO SHOT</div>`;
    const badges = [
      release.status
        ? `<span class="badge ${release.status === "done" ? "b-game" :
          release.status === "desktop" ? "b-desktop" : "b-failed"}">${esc(release.status)}</span>`
        : "",
      release.kind ? `<span class="badge b-other">${esc(release.kind)}</span>` : "",
      release.layer ? `<span class="badge b-layer">${esc(release.layer)}</span>` : "",
      release.ambiguous ? `<span class="badge b-amb">ambiguous</span>` : "",
    ].join("");
    const credits = [release.cracked_by, release.crew]
      .filter(Boolean).join(" · ");
    return `<div class="crew-release ${index === crewView.selected ? "selected" : ""}" ` +
      `data-idx="${index}" tabindex="-1">` +
      `<div class="crew-thumb">${preview}</div>` +
      `<div class="crew-release-body">` +
      `<div class="crew-release-badges">${badges}</div>` +
      `<div class="crew-release-title">${esc(release.title || release.zip || release.rel)}</div>` +
      `<div class="crew-release-meta">` +
      `${release.year ? esc(release.year) : ""}` +
      `${release.year && credits ? " · " : ""}${esc(credits)}</div>` +
      `</div></div>`;
  }).join("");
}

function crewRenderSide() {
  const side = $("crew-side");
  if (!crewView || !crewView.filtered.length) {
    side.innerHTML = `<div class="crew-side-empty">No release selected.</div>`;
    return;
  }
  crewView.selected = Math.max(0, Math.min(
    crewView.selected, crewView.filtered.length - 1));
  const release = crewView.filtered[crewView.selected];
  const rows = [];
  const add = (label, value) => {
    if (value !== "" && value != null && value !== false) {
      rows.push(`<tr><td>${esc(label)}</td><td>${esc(value)}</td></tr>`);
    }
  };
  add("Title", release.title);
  add("Year", release.year);
  add("Publisher", release.publisher);
  add("Cracked by", release.cracked_by);
  add("Crew", release.crew);
  add("Language", release.language);
  add("Disks", release.disks || "");
  const flags = [];
  if (release.raw_dump) flags.push("RAW");
  if (release.pasti_dump) flags.push("PASTI");
  if (release.boxscan) flags.push("Boxscan");
  if (release.tos_bad) flags.push("TOS/Bad");
  add("Flags", flags.join(", "));
  add("ZIP", release.zip);
  add("Status", release.status);
  add("Kind", release.kind);
  add("Layer", release.layer);
  if (release.ambiguous) add("Ambiguous", "yes");
  let html = `<h3>Release</h3><table>${rows.join("")}</table>`;
  if (release.found) {
    html += `<button type="button" id="crew-open">Open game lightbox</button>` +
      `<div class="crew-hint">Double-click / Enter opens the existing game lightbox.</div>`;
  } else {
    html += `<div class="crew-hint">Not found in the screenshot index — no game lightbox available.</div>`;
  }
  side.innerHTML = html;
}

function crewRenderSelection() {
  if (!crewView) return;
  document.querySelectorAll("#crew-grid .crew-release").forEach((el, index) => {
    el.classList.toggle("selected", index === crewView.selected);
  });
  const total = crewView.filtered.length;
  $("crew-pos").textContent = total
    ? `${crewView.selected + 1} / ${total}` : "0 / 0";
  crewRenderSide();
  const selected = $("crew-grid").querySelector(
    `.crew-release[data-idx="${crewView.selected}"]`);
  if (selected) selected.scrollIntoView({ block: "nearest" });
}

function renderCrewBrowser() {
  if (!crewView) return;
  const crew = crewView.group;
  $("crew-title").textContent = crew.name;
  $("crew-sub").textContent =
    `${crew.kind === "cracker" ? "Individual cracker" : "Crew"} · ` +
    `${crew.zips} ZIPs · ${crew.releases.length} releases`;
  const aliases = (crew.aliases || []).filter((a) => a !== crew.name);
  $("crew-aliases").textContent = aliases.length
    ? `Also known as: ${aliases.join(", ")}` : "";
  if ($("crew-search").value !== crewView.query) {
    $("crew-search").value = crewView.query;
  }
  $("crew-sort").value = crewView.sort;
  crewView.filtered = crewApplyFilter();
  if (crewView.selected >= crewView.filtered.length) {
    crewView.selected = Math.max(0, crewView.filtered.length - 1);
  }
  crewRenderGrid();
  crewRenderSelection();
}

function crewSelect(index) {
  if (!crewView || !crewView.filtered.length) return;
  crewView.selected = Math.max(0, Math.min(
    index, crewView.filtered.length - 1));
  crewRenderSelection();
}

function showCrewBrowser(crew) {
  crewView = {
    group: crew,
    releases: crew.releases || [],
    filtered: [],
    selected: 0,
    query: "",
    sort: "year_asc",
  };
  crewView.filtered = crewApplyFilter();
  const withPreview = crewView.filtered.findIndex((r) => r.preview);
  crewView.selected = withPreview >= 0 ? withPreview : 0;
  $("crew-lightbox").hidden = false;
  renderCrewBrowser();
  if (crewView.filtered.length) crewSelect(crewView.selected);
  requestAnimationFrame(() => $("crew-grid").focus());
}

async function openCrewBrowser(card) {
  try {
    const cached = crewCache.get(card.id);
    if (cached) {
      showCrewBrowser(cached);
      return;
    }
    const data = await api("/api/crews?id=" + encodeURIComponent(card.id));
    crewCache.set(card.id, data);
    showCrewBrowser(data);
  } catch (err) {
    showBanner("Cannot load crew releases: " + err.message, () => {
      hideBanner();
    });
  }
}

function closeCrewBrowser(restoreFocus = true) {
  crewView = null;
  $("crew-lightbox").hidden = true;
  if (restoreFocus) {
    const card = $("grid").querySelector(`.card[data-idx="${focusIdx}"]`);
    if (card) card.focus();
  }
}

async function crewOpenSelected() {
  if (!crewView || !crewView.filtered.length) return;
  const release = crewView.filtered[crewView.selected];
  if (!release || !release.found || !release.index_rel) return;
  try {
    const data = await api("/api/entries?section=cracked&entry=" +
      encodeURIComponent(release.index_rel));
    const card = data.cards && data.cards[0];
    if (!card) {
      showBanner("Release not found in the cracked catalog.");
      return;
    }
    const variant = card.variants.findIndex((v) => v.rel === release.index_rel);
    openStandaloneLightbox(card, variant >= 0 ? variant : 0);
  } catch (err) {
    showBanner("Cannot open release: " + err.message, () => hideBanner());
  }
}

function crewKeydown(e) {
  if (!crewView || lb) return;
  const inInput = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
  if (inInput) {
    if (e.key === "Escape") {
      if ($("crew-search").value) {
        $("crew-search").value = "";
        crewView.query = "";
        crewView.selected = 0;
        renderCrewBrowser();
        $("crew-grid").focus();
      } else {
        closeCrewBrowser();
      }
      e.preventDefault();
    }
    return;
  }
  const cols = crewColumns();
  switch (e.key) {
    case "ArrowRight":
      e.preventDefault();
      crewSelect(crewView.selected + 1);
      break;
    case "ArrowLeft":
      e.preventDefault();
      crewSelect(crewView.selected - 1);
      break;
    case "ArrowDown":
      e.preventDefault();
      crewSelect(crewView.selected + cols);
      break;
    case "ArrowUp":
      e.preventDefault();
      crewSelect(crewView.selected - cols);
      break;
    case "PageDown":
      e.preventDefault();
      crewSelect(crewView.selected + crewPageSize());
      break;
    case "PageUp":
      e.preventDefault();
      crewSelect(crewView.selected - crewPageSize());
      break;
    case "Home":
      e.preventDefault();
      crewSelect(0);
      break;
    case "End":
      e.preventDefault();
      crewSelect(crewView.filtered.length - 1);
      break;
    case "Enter":
      e.preventDefault();
      crewOpenSelected();
      break;
    case "Escape":
      e.preventDefault();
      closeCrewBrowser();
      break;
    case "/":
      e.preventDefault();
      $("crew-search").focus();
      break;
  }
}

function lbPrev() {
  if (!lb || lb.standalone) return;
  if (lb.idx > 0) {
    lb.idx--;
    // open on the first filmstrip entry (first variant with a screenshot)
    lb.variant = filmOrder(lb.cards[lb.idx])[0] || 0;
    lb.img = 0;
    renderLightbox();
    writeURL(true);
  }
}
function lbNext() {
  if (!lb || lb.standalone) return;
  if (lb.idx < lb.cards.length - 1) {
    lb.idx++;
    lb.variant = filmOrder(lb.cards[lb.idx])[0] || 0;
    lb.img = 0;
    renderLightbox();
    writeURL(true);
  }
}

// ---------------------------------------------------------------- keyboard
function gridCards() { return [...$("grid").querySelectorAll(".card")]; }

function setFocus(idx) {
  const cards = gridCards();
  if (!cards.length) return;
  focusIdx = Math.max(0, Math.min(idx, cards.length - 1));
  cards.forEach((c, i) => c.classList.toggle("kbd-focus", i === focusIdx));
  cards[focusIdx].focus({ preventScroll: false });
  cards[focusIdx].scrollIntoView({ block: "nearest" });
}

function gridKeydown(e) {
  if (lb) return; // lightbox handles its own keys
  const cards = gridCards();
  if (!cards.length) return;
  const cols = gridColumns();
  switch (e.key) {
    case "ArrowRight": e.preventDefault(); setFocus(Math.min(focusIdx + 1, cards.length - 1)); break;
    case "ArrowLeft": e.preventDefault(); setFocus(Math.max(focusIdx - 1, 0)); break;
    case "ArrowDown": e.preventDefault(); setFocus(Math.min(focusIdx + cols, cards.length - 1)); break;
    case "ArrowUp": e.preventDefault(); setFocus(Math.max(focusIdx - cols, 0)); break;
    case "Home": e.preventDefault(); setFocus(0); break;
    case "End": e.preventDefault(); setFocus(cards.length - 1); break;
    case "Enter": case " ":
      e.preventDefault();
      if (focusIdx >= 0) {
        if (isCrewCard(pageCards[focusIdx])) {
          openCrewBrowser(pageCards[focusIdx]);
        } else {
          const fv = parseInt(cards[focusIdx].dataset.v || "0", 10);
          openLightbox(focusIdx, fv);
        }
      }
      break;
    case "Escape":
      focusIdx = -1;
      cards.forEach((c) => c.classList.remove("kbd-focus"));
      break;
    case "PageDown": e.preventDefault(); changePage(1); break;
    case "PageUp": e.preventDefault(); changePage(-1); break;
    // "/" falls through to globalKeydown (document-level handler)
  }
}

function gridColumns() {
  const grid = $("grid");
  const card = grid.querySelector(".card");
  if (!card) return 1;
  const style = getComputedStyle(grid);
  const gap = parseFloat(style.gap) || 14;
  const w = card.getBoundingClientRect().width + gap;
  return Math.max(1, Math.round(grid.clientWidth / w));
}

// ---------------------------------------------------------------- help
function openHelp() { $("help").hidden = false; }
function closeHelp() { $("help").hidden = true; }

function globalKeydown(e) {
  const inInput = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
  if (!$("help").hidden) {
    // any key closes the help; auto-repeat is ignored so a held key does
    // not flicker it (desktop `help_overlay.dart`)
    if (!e.repeat) { e.preventDefault(); closeHelp(); }
    return;
  }
  if (crewView && !lb) return;
  if (e.key === "Escape") {
    if (lb) { e.preventDefault(); closeLightbox(); return; }
    if (inInput && document.activeElement.id === "search") {
      state.q = "";
      $("search").value = "";
      state.offset = 0;
      loadEntries();
      $("grid").focus();
      return;
    }
  }
  if (lb) {
    switch (e.key) {
      case "ArrowLeft": e.preventDefault(); lbPrev(); return;
      case "ArrowRight": e.preventDefault(); lbNext(); return;
      case "ArrowDown": e.preventDefault(); lbMoveVariant(1); return;
      case "ArrowUp": e.preventDefault(); lbMoveVariant(-1); return;
      case "PageDown": { e.preventDefault(); const imgs = lightboxImages(lb.cards[lb.idx]); if (imgs.length) { lb.img = (lb.img + 1) % imgs.length; renderLightbox(); } return; }
      case "PageUp": { e.preventDefault(); const imgs = lightboxImages(lb.cards[lb.idx]); if (imgs.length) { lb.img = (lb.img - 1 + imgs.length) % imgs.length; renderLightbox(); } return; }
    }
    return;
  }
  if (!inInput && e.key === "?") {
    e.preventDefault();
    openHelp();
    return;
  }
  if (!inInput && e.key === "/") {
    e.preventDefault();
    $("search").focus();
  }
}

// ---------------------------------------------------------------- paging
function changePage(dir) {
  state.offset = Math.max(0, state.offset + dir * state.limit);
  loadEntries().then(() => {
    $("grid").scrollIntoView({ block: "start" });
  });
}

// ---------------------------------------------------------------- events
function wireEvents() {
  $("grid").addEventListener("keydown", gridKeydown);
  document.addEventListener("keydown", globalKeydown);
  // the hover panel is position:fixed — dismiss it on key press (SPEC 6.1)
  // and whenever the grid scrolls under it
  document.addEventListener("keydown", hideHover);
  window.addEventListener("scroll", hideHover, true);
  // help overlay: click on the backdrop closes it
  $("help").addEventListener("click", (e) => {
    if (e.target === $("help")) closeHelp();
  });
  window.addEventListener("popstate", () => {
    readURL();
    syncControls();
    loadEntries();
  });

  // grid: click, hover, candidate clicks
  $("grid").addEventListener("click", (e) => {
    const cand = e.target.closest("img[data-cand]");
    const varV = e.target.closest("img[data-varv]");
    const cardEl = e.target.closest(".card");
    if (!cardEl) return;
    const idx = parseInt(cardEl.dataset.idx, 10);
    const fv = parseInt(cardEl.dataset.v || "0", 10);
    if (isCrewCard(pageCards[idx])) {
      openCrewBrowser(pageCards[idx]);
      return;
    }
    if (varV) {
      openLightbox(idx, parseInt(varV.dataset.varv, 10) || 0);
      return;
    }
    if (cand) {
      const src = pageCards[idx].variants[fv] || pageCards[idx].variants[0] || {};
      const cands = src.candidates || [];
      const ci = cands.findIndex((p) => imgSrc(p) === cand.getAttribute("src"));
      openLightbox(idx, fv, ci >= 0 ? ci + 1 : 0);
      return;
    }
    openLightbox(idx, fv);
  });
  $("grid").addEventListener("mouseover", (e) => {
    if (!canHover()) return;
    const cardEl = e.target.closest(".card");
    if (!cardEl) return;
    const idx = parseInt(cardEl.dataset.idx, 10);
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(() => showHover(pageCards[idx], cardEl), 400);
  });
  $("grid").addEventListener("mouseout", (e) => {
    if (e.target.closest(".card")) hideHover();
  });
  $("grid").addEventListener("focusin", (e) => {
    const cardEl = e.target.closest(".card");
    if (!cardEl) return;
    focusIdx = parseInt(cardEl.dataset.idx, 10);
    gridCards().forEach((c, i) => c.classList.toggle("kbd-focus", i === focusIdx));
  });

  // controls
  $("search").addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      state.q = $("search").value.trim();
      state.offset = 0;
      loadEntries();
    }, 250);
  });
  for (const id of ["status", "publisher", "crew", "cracker", "language",
    "year", "raw", "pasti", "boxscan", "tos"]) {
    $(id).addEventListener("change", () => {
      state[id] = $(id).value;
      state.offset = 0;
      loadEntries();
    });
  }
  // combined sort + order dropdown, value `<key>:<order>` (desktop
  // `_sortDropdown`); the URL keeps the separate `sort`/`order` params
  $("sort").addEventListener("change", () => {
    const [k, o] = $("sort").value.split(":");
    state.sort = SORT_KEYS.includes(k) ? k : "name";
    state.order = o === "desc" ? "desc" : "asc";
    state.offset = 0;
    loadEntries();
  });
  const clearAll = () => {
    Object.assign(state, {
      status: sectionDefaultStatus(), q: "", letter: "any",
      publisher: "any", crew: "any", cracker: "any", language: "any",
      year: "any", raw: "any", pasti: "any", boxscan: "any", tos: "any",
      sort: "name", order: "asc", offset: 0,
    });
    syncControls();
    loadEntries();
  };
  $("clear").addEventListener("click", clearAll);
  $("empty-clear").addEventListener("click", clearAll);

  $("letters").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-letter]");
    if (!b) return;
    state.letter = b.dataset.letter;
    state.offset = 0;
    buildLetters();
    loadEntries();
  });

  $("tabs").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-section]");
    if (!b) return;
    state.section = b.dataset.section;
    state.offset = 0;
    // reset incompatible filters; status falls back to the section default
    state.status = sectionDefaultStatus();
    for (const k of ["raw", "pasti", "boxscan", "tos", "crew", "cracker"])
      state[k] = "any";
    if (state.section === "crew") {
      state.letter = "any";
      state.sort = "name";
      state.order = "asc";
      for (const k of ["publisher", "language", "year"]) state[k] = "any";
    } else if (state.sort === "cracker" &&
        !["cracked", "utils"].includes(state.section)) {
      state.sort = "name";
    }
    syncControls();
    loadEntries();
  });

  $("page-prev").addEventListener("click", () => changePage(-1));
  $("page-next").addEventListener("click", () => changePage(1));

  // lightbox
  $("lb-close").addEventListener("click", closeLightbox);
  $("lb-prev").addEventListener("click", lbPrev);
  $("lb-next").addEventListener("click", lbNext);
  $("lightbox").addEventListener("click", (e) => {
    if (e.target === $("lightbox")) closeLightbox();
    // clickable crew/cracker group (Game info values, release-variant rows)
    const gl = e.target.closest(".lb-link");
    if (gl) {
      e.preventDefault();
      lbSelectGroup(gl.dataset.groupVal, gl.dataset.group);
      return;
    }
    const fi = e.target.closest(".lb-film-item");
    if (fi) { lb.variant = parseInt(fi.dataset.v, 10); lb.img = 0; renderLightbox(); writeURL(false); }
    const ci = e.target.closest("#lb-cands img");
    if (ci) { lb.img = parseInt(ci.dataset.img, 10); renderLightbox(); }
  });

  // crew release browser
  $("crew-close").addEventListener("click", () => closeCrewBrowser());
  $("crew-lightbox").addEventListener("click", (e) => {
    if (e.target === $("crew-lightbox")) closeCrewBrowser();
  });
  $("crew-grid").addEventListener("click", (e) => {
    const release = e.target.closest(".crew-release");
    if (!release) return;
    crewSelect(parseInt(release.dataset.idx, 10));
  });
  $("crew-grid").addEventListener("dblclick", (e) => {
    const release = e.target.closest(".crew-release");
    if (!release) return;
    crewSelect(parseInt(release.dataset.idx, 10));
    crewOpenSelected();
  });
  $("crew-side").addEventListener("click", (e) => {
    if (e.target.closest("#crew-open")) crewOpenSelected();
  });
  $("crew-search").addEventListener("input", () => {
    clearTimeout(crewSearchTimer);
    crewSearchTimer = setTimeout(() => {
      if (!crewView) return;
      crewView.query = $("crew-search").value;
      crewView.selected = 0;
      renderCrewBrowser();
    }, 120);
  });
  $("crew-sort").addEventListener("change", () => {
    if (!crewView) return;
    crewView.sort = $("crew-sort").value;
    crewView.selected = 0;
    renderCrewBrowser();
    $("crew-grid").focus();
  });
  document.addEventListener("keydown", crewKeydown);
}

function syncControls() {
  $("search").value = state.q;
  buildStatusOptions();
  buildFacets();
  buildLetters();
  for (const b of $("tabs").querySelectorAll("button")) {
    b.classList.toggle("active", b.dataset.section === state.section);
  }
}

// ---------------------------------------------------------------- boot
async function boot() {
  const urlStatus = new URLSearchParams(location.search).has("status");
  readURL();
  wireEvents();
  try {
    meta = await api("/api/meta");
    hideBanner();
  } catch (err) {
    showBanner("Cannot load metadata: " + err.message, () => location.reload());
    return;
  }
  if (meta.show_candidates != null) showCands = !!meta.show_candidates;
  if (meta.default_status) defaultStatus = meta.default_status;
  if (!urlStatus) state.status = sectionDefaultStatus();
  // show the section tabs when a non-default section has any card (index-
  // or gameinfo-derived), even without gameinfo; hide empty tabs individually
  const secMeta = (meta && meta.sections) || {};
  const secHasData = (s) => !!(secMeta[s] && (secMeta[s].games || secMeta[s].cards));
  const crewAvailable = !!(meta.crews && meta.crews.available);
  if (state.section === "crew" && !crewAvailable) state.section = "cracked";
  $("tabs").hidden = !(crewAvailable || secHasData("pd") ||
    secHasData("utils") || secHasData("magazine") || secHasData("falcon"));
  for (const b of $("tabs").querySelectorAll("button")) {
    const s = b.dataset.section;
    b.hidden = s === "crew" ? !crewAvailable
      : (s !== "cracked" && !secHasData(s));
  }
  syncControls();
  renderStats();
  renderFooter();
  await loadEntries();

  // consume deep link ?entry=
  if (state.entry) {
    const rel = state.entry;
    state.entry = null;
    try {
      const data = await api("/api/entries?entry=" + encodeURIComponent(rel) +
        "&sort=" + encodeURIComponent(state.sort) +
        "&order=" + encodeURIComponent(state.order) +
        "&status=" + encodeURIComponent(state.status) +
        "&section=" + encodeURIComponent(state.section));
      const card = data.cards && data.cards[0];
      if (card) {
        const vi = card.variants.findIndex((vv) => vv.rel === rel);
        const variant = vi >= 0 ? vi : 0;
        // jump to the page that really contains the card (SPEC 6.9)
        if (card.position != null) {
          const target = Math.floor(card.position / state.limit) * state.limit;
          if (target !== state.offset) {
            state.offset = target;
            await loadEntries();
          }
        }
        const local = pageCards.findIndex((c) => c.id === card.id);
        if (local >= 0) {
          openLightbox(local, variant);
        } else {
          // card filtered out of the current view — inject as a fallback
          pageCards.unshift(card);
          renderGrid(pageCards);
          openLightbox(0, variant);
        }
      }
    } catch (err) {
      showBanner("Deep link not found: " + rel);
    }
  }
}

boot();
