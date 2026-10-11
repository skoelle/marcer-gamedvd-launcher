/* Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
   Licensed under the MIT License. See LICENSE file in project root.
   Gallery frontend: grid, filters, lightbox, keyboard, deep links. */
"use strict";

const STATUS_OPTIONS = [
  ["with_screenshot", "with screenshot"],
  ["any", "any status"],
  ["done", "done (game)"],
  ["desktop", "desktop"],
  ["no_usable_shots", "no usable shots"],
  ["interrupted", "interrupted"],
  ["pending", "pending"],
  ["skipped_disk_n", "skipped (disk 2+)"],
];
const TRI_OPTIONS = [["any", "any"], ["yes", "yes"], ["no", "no"]];
const LETTERS = ["0-9", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("")];

const SECTION_CONTROLS = {
  cracked: ["status", "publisher", "crew", "language", "year",
            "raw", "pasti", "boxscan", "tos"],
  pd: ["publisher", "language", "year"],
  utils: ["publisher", "crew", "language", "year", "raw", "tos"],
};
const FACET_LABELS = {
  status: "Status", publisher: "Publisher", crew: "Crew",
  language: "Language", year: "Year", raw: "RAW", pasti: "PASTI",
  boxscan: "Boxscan", tos: "TOS/Bad",
};

const state = {
  section: "cracked",
  status: "with_screenshot",
  q: "",
  letter: "any",
  publisher: "any",
  crew: "any",
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

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;");
const imgSrc = (p) => "/img/" + p.split("/").map(encodeURIComponent).join("/");

// ---------------------------------------------------------------- state <-> URL
function readURL() {
  const u = new URLSearchParams(location.search);
  for (const key of ["section", "status", "q", "letter", "publisher",
    "crew", "language", "year", "raw", "pasti", "boxscan", "tos",
    "sort", "order"]) {
    if (u.has(key)) state[key] = u.get(key);
  }
  if (u.has("offset")) state.offset = Math.max(0, parseInt(u.get("offset"), 10) || 0);
  if (u.has("entry")) state.entry = u.get("entry");
  if (!["cracked", "pd", "utils"].includes(state.section)) state.section = "cracked";
}

function writeURL(push) {
  const u = new URLSearchParams();
  const keep = (k, v, dflt) => {
    if (v != null && v !== "" && v !== dflt) u.set(k, v);
  };
  keep("section", state.section, "cracked");
  keep("status", state.status, "with_screenshot");
  keep("q", state.q, "");
  keep("letter", state.letter, "any");
  for (const k of ["publisher", "crew", "language", "year",
    "raw", "pasti", "boxscan", "tos"]) keep(k, state[k], "any");
  keep("sort", state.sort, "name");
  keep("order", state.order, "asc");
  keep("offset", state.offset ? String(state.offset) : "", "0");
  if (lb && pageCards[lb.idx] && pageCards[lb.idx].variants[lb.variant]) {
    u.set("entry", pageCards[lb.idx].variants[lb.variant].rel);
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
  if (state.section === "cracked") p.set("status", state.status);
  if (state.q) p.set("q", state.q);
  if (state.letter !== "any") p.set("letter", state.letter);
  const fields = SECTION_CONTROLS[state.section] || [];
  for (const k of ["publisher", "crew", "language", "year",
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
  const facets = (meta && meta.facets && meta.facets[section]) || {};
  const fields = SECTION_CONTROLS[section] || [];
  // hide controls not available for this section / without gameinfo
  for (const id of ["status", "publisher", "crew", "language", "year",
    "raw", "pasti", "boxscan", "tos", "sort", "order", "clear", "search"]) {
    const el = $(id);
    if (!el) continue;
    if (id === "sort" || id === "order" || id === "clear" || id === "search") {
      el.hidden = false;
      continue;
    }
    el.hidden = !fields.includes(id);
  }
  if (!meta || !meta.gameinfo) {
    for (const id of ["publisher", "crew", "language", "year",
      "raw", "pasti", "boxscan", "tos"]) $(id).hidden = true;
  } else {
    facetOptions("publisher", facets.publishers || [], "Publisher: any");
    facetOptions("crew", facets.crews || [], "Crew: any");
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
  $("sort").value = ["name", "year", "publisher", "cracker", "crew"]
    .includes(state.sort) ? state.sort : "name";
  $("order").textContent = state.order;
}

function buildLetters() {
  const box = $("letters");
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
  const sc = meta.status_counts || {};
  const parts = [];
  if (meta.gameinfo && meta.sections && meta.sections.cracked) {
    const s = meta.sections.cracked;
    parts.push(`<span class="st"><b>${s.with_screenshot}</b> / ${meta.index.entries} with screenshot</span>`);
  } else {
    parts.push(`<span class="st"><b>${meta.index.entries}</b> index entries</span>`);
  }
  const order = ["done", "desktop", "pending", "skipped_disk_n",
    "no_usable_shots", "interrupted"];
  for (const k of order) {
    if (sc[k]) parts.push(`<span class="st">${esc(k)} <b>${sc[k]}</b></span>`);
  }
  if (meta.coverage && meta.coverage.matched_folders != null) {
    parts.push(`<span class="st">info <b>${meta.coverage.matched_folders}</b> folders</span>`);
  }
  if (extra) parts.push(`<span class="hint">${esc(extra)}</span>`);
  $("stats").innerHTML = parts.join("");
}

function renderFooter() {
  if (!meta) return;
  const bits = [];
  if (meta.index.mtime) {
    bits.push("index.json: " + new Date(meta.index.mtime * 1000).toLocaleString());
  }
  if (meta.generated_at) bits.push("gameinfo: " + meta.generated_at);
  bits.push("gallery " + meta.tool_version);
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
  const showCands = true;
  grid.innerHTML = cards.map((c, i) => {
    const nzip = c.variants.length;
    const chip = nzip > 1 ? `<span class="chip">×${nzip}</span>` : "";
    const layer = c.layer ? `<span class="layer">${esc(c.layer)}</span>` : "";
    const fv = (c.focus_variant != null && c.focus_variant >= 0)
      ? c.focus_variant : 0;
    let body;
    if (c.preview) {
      body = `<img loading="lazy" src="${imgSrc(c.preview)}" alt="">`;
      if (showCands) {
        const src = c.variants[fv] || c.variants[0] || {};
        const cands = src.candidates || [];
        if (cands.length && (c.focus_variant == null || c.focus_variant < 0)
            && c.variants.length === 1) {
          body += `<div class="cands">` +
            cands.map((p) => `<img loading="lazy" src="${imgSrc(p)}" alt="" data-cand="${i}">`).join("") +
            `</div>`;
        }
      }
    } else {
      body = `<div class="ph"></div>`;
    }
    return `<div class="card" data-idx="${i}" data-v="${fv}" tabindex="-1">` +
      `${badgeFor(c)}${chip}${layer}` +
      `<div class="name">${esc(c.name)}</div>${body}</div>`;
  }).join("");
  $("pager").hidden = false;
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
    const data = await api(entriesQuery());
    renderGrid(data.cards);
    renderPager(data.total);
    $("result-count").textContent = `${data.total} results`;
    writeURL(false);
  } catch (err) {
    showBanner(err.message, () => loadEntries());
    $("grid").innerHTML = "";
    $("pager").hidden = true;
  }
}

// ---------------------------------------------------------------- hover panel
let hoverTimer = null;
function hoverHTML(card) {
  const rows = [];
  const add = (k, v) => {
    if (v !== "" && v != null && v !== false) rows.push(
      `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`);
  };
  if (card.info) {
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
  lb = { idx, variant: variant || 0, img: img || 0 };
  $("lightbox").hidden = false;
  renderLightbox();
  writeURL(true);
}

function closeLightbox() {
  lb = null;
  $("lightbox").hidden = true;
  writeURL(false);
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

// integer-only upscale of the lightbox main image (pixel-art safe)
function fitIntegerScale(img) {
  if (!img || !img.naturalWidth) return;
  const wrap = img.parentElement;
  if (!wrap) return;
  const availW = wrap.clientWidth;
  const availH = wrap.clientHeight;
  if (!availW || !availH) return;
  const scale = Math.max(1, Math.floor(Math.min(
    availW / img.naturalWidth,
    availH / img.naturalHeight
  )));
  img.style.width = (img.naturalWidth * scale) + "px";
  img.style.height = (img.naturalHeight * scale) + "px";
}

function renderLightbox() {
  if (!lb) return;
  const card = pageCards[lb.idx];
  if (!card) return closeLightbox();
  lb.variant = Math.min(lb.variant, Math.max(0, card.variants.length - 1));

  $("lb-badge").innerHTML = badgeFor(card);
  $("lb-title").textContent = card.name;
  const v = card.variants[lb.variant];
  $("lb-sub").textContent = v
    ? `${v.status}${v.layer ? " · " + v.layer : ""}${v.size ? " · " + Math.round(v.size / 1024) + " KB" : ""}`
    : "no ZIP variants";
  $("lb-pos").textContent = `${lb.idx + 1} / ${pageCards.length}`;

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

  // filmstrip: one thumb per variant (hover shows full ZIP name via title)
  $("lb-film").innerHTML = card.variants.map((vv, i) => {
    const thumb = vv.preview
      ? `<img src="${imgSrc(vv.preview)}" alt="" loading="lazy">`
      : `<div class="ph-thumb">–</div>`;
    const st = vv.preview ? `st-${vv.status === "done" ? "done" : "desktop"}` : "st-empty";
    const short = vv.name.replace(/\.zip$/i, "").replace(/^[^-]*-\s*/, "");
    const nCand = (vv.candidates || []).length;
    const badge = nCand > 1 ? `<span class="cand-count">(${nCand})</span>` : "";
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
    const add = (k, val) => {
      if (val !== "" && val != null && val !== false) {
        rows.push(`<tr><td>${esc(k)}</td><td>${esc(val)}</td></tr>`);
      }
    };
    add("Title", i.title);
    add("Publisher", i.publisher);
    add("Cracked by", i.cracked_by);
    add("Crew", i.crew);
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
    let html = `<h3>Game info</h3><table>${rows.join("")}</table>`;
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
      html += `<h3>Release variants (${i.variants.length})</h3>` +
        `<table class="variants-table"><tr>` +
        `<th>Title</th><th>Cracker</th><th>Crew</th><th>Year</th></tr>` +
        i.variants.map((rv, ri) =>
          `<tr class="${ri === selIdx ? "selected" : ""}"><td>${esc(rv.title)}</td><td>${esc(rv.cracked_by)}</td>` +
          `<td>${esc(rv.crew)}</td><td>${esc(rv.release)}</td></tr>`).join("") +
        `</table>`;
    }
    if (v) {
      html += `<h3>This ZIP</h3><table>` +
        `<tr><td>File</td><td>${esc(v.name)}</td></tr>` +
        `<tr><td>Status</td><td>${esc(v.status)}</td></tr>` +
        (v.layer ? `<tr><td>Layer</td><td>${esc(v.layer)}</td></tr>` : "") +
        (v.size ? `<tr><td>Size</td><td>${(v.size / 1024).toFixed(0)} KB</td></tr>` : "") +
        `<tr><td>Path</td><td>${esc(v.rel)}</td></tr></table>`;
    }
    side.innerHTML = html;
  } else {
    let html = `<h3>No game info</h3>`;
    if (v) {
      html += `<table><tr><td>File</td><td>${esc(v.name)}</td></tr>` +
        `<tr><td>Status</td><td>${esc(v.status)}</td></tr>` +
        (v.layer ? `<tr><td>Layer</td><td>${esc(v.layer)}</td></tr>` : "") +
        `<tr><td>Path</td><td>${esc(v.rel)}</td></tr></table>`;
    }
    side.innerHTML = html;
  }
}

function lbPrev() {
  if (!lb) return;
  if (lb.idx > 0) { lb.idx--; lb.variant = 0; lb.img = 0; renderLightbox(); writeURL(true); }
}
function lbNext() {
  if (!lb) return;
  if (lb.idx < pageCards.length - 1) { lb.idx++; lb.variant = 0; lb.img = 0; renderLightbox(); writeURL(true); }
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
        const fv = parseInt(cards[focusIdx].dataset.v || "0", 10);
        openLightbox(focusIdx, fv);
      }
      break;
    case "Escape":
      focusIdx = -1;
      cards.forEach((c) => c.classList.remove("kbd-focus"));
      break;
    case "PageDown": e.preventDefault(); changePage(1); break;
    case "PageUp": e.preventDefault(); changePage(-1); break;
    default:
      if (e.key === "/") { e.preventDefault(); $("search").focus(); }
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

function globalKeydown(e) {
  const inInput = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
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
      case "ArrowDown": {
        e.preventDefault();
        const card = pageCards[lb.idx];
        const n = card.variants.length;
        if (n > 1) { lb.variant = (lb.variant + 1) % n; lb.img = 0; renderLightbox(); writeURL(false); }
        return;
      }
      case "ArrowUp": {
        e.preventDefault();
        const card = pageCards[lb.idx];
        const n = card.variants.length;
        if (n > 1) { lb.variant = (lb.variant - 1 + n) % n; lb.img = 0; renderLightbox(); writeURL(false); }
        return;
      }
      case "PageDown": { e.preventDefault(); const imgs = lightboxImages(pageCards[lb.idx]); if (imgs.length) { lb.img = (lb.img + 1) % imgs.length; renderLightbox(); } return; }
      case "PageUp": { e.preventDefault(); const imgs = lightboxImages(pageCards[lb.idx]); if (imgs.length) { lb.img = (lb.img - 1 + imgs.length) % imgs.length; renderLightbox(); } return; }
    }
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
  window.addEventListener("popstate", () => {
    readURL();
    syncControls();
    loadEntries();
  });

  // grid: click, hover, candidate clicks
  $("grid").addEventListener("click", (e) => {
    const cand = e.target.closest("img[data-cand]");
    const cardEl = e.target.closest(".card");
    if (!cardEl) return;
    const idx = parseInt(cardEl.dataset.idx, 10);
    const fv = parseInt(cardEl.dataset.v || "0", 10);
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
  for (const id of ["status", "publisher", "crew", "language", "year",
    "raw", "pasti", "boxscan", "tos", "sort"]) {
    $(id).addEventListener("change", () => {
      state[id] = $(id).value;
      state.offset = 0;
      loadEntries();
    });
  }
  $("order").addEventListener("click", () => {
    state.order = state.order === "asc" ? "desc" : "asc";
    $("order").textContent = state.order;
    state.offset = 0;
    loadEntries();
  });
  const clearAll = () => {
    Object.assign(state, {
      status: "with_screenshot", q: "", letter: "any",
      publisher: "any", crew: "any", language: "any", year: "any",
      raw: "any", pasti: "any", boxscan: "any", tos: "any",
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
    // reset incompatible filters
    state.status = "with_screenshot";
    for (const k of ["raw", "pasti", "boxscan", "tos", "crew"]) state[k] = "any";
    if (state.sort === "cracker" && state.section === "pd") state.sort = "name";
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
    const fi = e.target.closest(".lb-film-item");
    if (fi) { lb.variant = parseInt(fi.dataset.v, 10); lb.img = 0; renderLightbox(); writeURL(false); }
    const ci = e.target.closest("#lb-cands img");
    if (ci) { lb.img = parseInt(ci.dataset.img, 10); renderLightbox(); }
  });
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
  readURL();
  wireEvents();
  try {
    meta = await api("/api/meta");
    hideBanner();
  } catch (err) {
    showBanner("Cannot load metadata: " + err.message, () => location.reload());
    return;
  }
  $("tabs").hidden = !(meta.gameinfo && meta.sections &&
    (meta.sections.pd.games || meta.sections.utils.games));
  syncControls();
  renderStats();
  renderFooter();
  await loadEntries();

  // consume deep link ?entry=
  if (state.entry) {
    const rel = state.entry;
    state.entry = null;
    try {
      const data = await api("/api/entries?entry=" + encodeURIComponent(rel));
      const card = data.cards && data.cards[0];
      if (card) {
        const vi = card.variants.findIndex((vv) => vv.rel === rel);
        const variant = vi >= 0 ? vi : 0;
        // if the card is on the current page, open at that index; else inject
        const local = pageCards.findIndex((c) => c.id === card.id);
        if (local >= 0) openLightbox(local, variant);
        else {
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
