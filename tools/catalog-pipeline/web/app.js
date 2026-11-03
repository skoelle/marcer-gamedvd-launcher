/* Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
   Licensed under the MIT License. See LICENSE file in project root. */

const REFRESH_MS = 5000;
const STATUS_ORDER = [
  "done", "desktop", "no_usable_shots", "pending",
  "error", "interrupted", "timeout", "skipped_disk_n", "unknown",
];

const els = {
  cards: document.getElementById("cards"),
  runs: document.getElementById("runs"),
  banner: document.getElementById("banner"),
  version: document.getElementById("version"),
  updated: document.getElementById("updated"),
};

function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function fmtBytes(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "–";
  let n = Number(value);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
  return `${n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)} ${units[i]}`;
}

function fmtTime(value) {
  if (!value) return "–";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return esc(value);
  return esc(date.toLocaleString());
}

function fmtAge(hours) {
  if (hours === null || hours === undefined) return "–";
  const h = Number(hours);
  if (h < 1) return `${Math.max(1, Math.round(h * 60))} min`;
  if (h < 48) return `${h.toFixed(1)} h`;
  return `${(h / 24).toFixed(1)} d`;
}

function fmtDuration(start, end) {
  if (!start || !end) return "–";
  const a = new Date(start).getTime();
  const b = new Date(end).getTime();
  if (Number.isNaN(a) || Number.isNaN(b) || b < a) return "–";
  const seconds = Math.round((b - a) / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}

function badge(text, kind = "") {
  return `<span class="badge${kind ? ` badge-${kind}` : ""}">${esc(text)}</span>`;
}

function statusKind(status) {
  if (["ok", "uploaded", "done"].includes(status)) return "ok";
  if (["pending", "dirty", "dry-run", "degraded"].includes(status)) return "warn";
  if (["error", "missing", "interrupted"].includes(status)) return "bad";
  return "";
}

function card(title, body, statusBadge = "") {
  return `<section class="card"><div class="card-head"><h2>${esc(title)}</h2>${statusBadge}</div>${body}</section>`;
}

function kv(pairs) {
  return `<div class="kv">${pairs
    .map(([label, value]) => `<span>${esc(label)} <b>${esc(value)}</b></span>`)
    .join("")}</div>`;
}

function chips(counts, badKeys = [], warnKeys = []) {
  return `<div class="chips">${Object.entries(counts || {})
    .map(([key, value]) => {
      const cls = badKeys.includes(key) ? " bad" : warnKeys.includes(key) ? " warn" : "";
      return `<span class="chip${cls}">${esc(key)} <b>${esc(value)}</b></span>`;
    })
    .join("")}</div>`;
}

function listWarnings(items, className = "warn-list") {
  if (!items || !items.length) return "";
  return `<ul class="${className}">${items.map((item) => `<li>${esc(item)}</li>`).join("")}</ul>`;
}

function renderSync(sync) {
  const counts = sync.counts || {};
  const bad = (counts.download_errors || 0) + (counts.incomplete_dirs || 0);
  const kind = !sync.present ? "bad" : bad > 0 ? "warn" : "ok";
  const label = !sync.present ? "missing" : bad > 0 ? "warnings" : "ok";
  return card(
    "Sync",
    kv([
      ["last run", fmtTime(sync.generated_at)],
      ["mode", sync.mode || "–"],
    ]) + chips(counts, ["download_errors", "incomplete_dirs"], ["local_only", "warnings"])
      + listWarnings(sync.incomplete_dirs),
    badge(label, kind),
  );
}

function renderGameinfo(info) {
  const kind = info.present ? "ok" : "bad";
  const sources = Array.isArray(info.sources) ? info.sources : [];
  const sourceRows = sources.map((source) => `<tr>
      <td>${esc(source.kind || "–")}</td>
      <td class="num">${esc(source.matched_folders ?? "–")}</td>
      <td>${fmtTime(source.mtime)}</td>
    </tr>`).join("");
  const files = Array.isArray(info.files) ? info.files : [];
  const fileRows = files.map((file) => `<tr>
      <td>${esc(file.name)}</td>
      <td class="num">${fmtBytes(file.size)}</td>
      <td>${fmtAge(file.age_hours)}</td>
    </tr>`).join("");
  const body = kv([
    ["generated", fmtTime(info.generated_at)],
    ["generator", info.generator || "–"],
  ]) + (sourceRows ? `<div class="table-wrap" style="margin-top:10px"><table>
      <thead><tr><th>source</th><th class="num">folders</th><th>mtime</th></tr></thead>
      <tbody>${sourceRows}</tbody></table></div>` : "")
    + (fileRows ? `<div class="table-wrap" style="margin-top:10px"><table>
      <thead><tr><th>file</th><th class="num">size</th><th>age</th></tr></thead>
      <tbody>${fileRows}</tbody></table></div>` : "");
  return card("Gameinfo", body, badge(info.present ? "ok" : "missing", kind));
}

function renderFullIndex(index) {
  const counts = index.counts || {};
  const errors = index.error_count || 0;
  const body = kv([
    ["generated file", fmtTime(index.file?.mtime)],
    ["age", fmtAge(index.file?.age_hours)],
  ]) + chips({
    zips: counts.zips ?? "–",
    members: counts.members ?? "–",
    errors,
  }, ["errors"]);
  return card("Full index", body, badge(index.present ? (errors ? "warnings" : "ok") : "missing",
    index.present ? (errors ? "warn" : "ok") : "bad"));
}

function renderCrews(crews) {
  const body = kv([
    ["generated", fmtTime(crews.generated_at)],
    ["groups", crews.groups ?? "–"],
  ]);
  return card("Crews", body, badge(crews.present ? "ok" : "missing",
    crews.present ? "ok" : "bad"));
}

function renderPublish(publish) {
  const status = publish.status || "missing";
  const body = kv([
    ["archive", publish.archive || "–"],
    ["size", fmtBytes(publish.size)],
    ["uploaded", publish.uploaded ? "yes" : "no"],
    ["manifest dirty", publish.manifest_dirty ? "yes" : "no"],
    ["updated", fmtTime(publish.updated_at)],
  ]) + (publish.archive_exists === false
    ? listWarnings(["archive is recorded but not present locally"])
    : "");
  return card("Publish", body, badge(status, statusKind(status)));
}

function renderScreenshots(shots) {
  if (!shots.present) {
    return card("Screenshots", `<p class="muted">${esc(shots.error || "no screenshot index")}</p>`,
      badge("missing", "bad"));
  }
  const rows = Object.entries(shots.scopes || {}).map(([name, scope]) => {
    const counts = scope.counts || {};
    const errors = (counts.error || 0) + (counts.interrupted || 0) + (counts.timeout || 0);
    return `<tr>
      <td>${esc(name)}</td>
      <td class="num">${esc(scope.total ?? 0)}</td>
      <td class="num">${esc(counts.done ?? 0)}</td>
      <td class="num">${esc(counts.desktop ?? 0)}</td>
      <td class="num">${esc(counts.no_usable_shots ?? 0)}</td>
      <td class="num">${esc(counts.pending ?? 0)}</td>
      <td class="num">${errors}</td>
      <td class="num">${scope.bytes_partial ? "≥ " : ""}${fmtBytes(scope.bytes)}</td>
      <td>${fmtAge(scope.age_hours)}</td>
    </tr>`;
  }).join("");
  const body = `<div class="table-wrap"><table>
      <thead><tr><th>scope</th><th class="num">total</th><th class="num">done</th>
      <th class="num">desktop</th><th class="num">no usable</th><th class="num">pending</th>
      <th class="num">errors</th><th class="num">size</th><th>age</th></tr></thead>
      <tbody>${rows}</tbody></table></div>
    <div class="chips">
      <span class="chip${shots.without_preview ? " warn" : ""}">without preview <b>${esc(shots.without_preview ?? 0)}</b></span>
      <span class="chip">oldest index <b>${fmtAge(shots.index_age_hours)}</b></span>
      ${shots.bytes_partial ? '<span class="chip warn">image sizes <b>partial</b></span>' : ""}
    </div>`;
  return card("Screenshots", body, badge("read-only", ""));
}

function renderStorage(storage) {
  const rows = Object.entries(storage || {}).map(([name, usage]) => {
    if (!usage) return `<tr><td>${esc(name)}</td><td colspan="3" class="muted">unavailable</td></tr>`;
    const pct = usage.total_bytes ? Math.round((usage.used_bytes / usage.total_bytes) * 100) : 0;
    return `<tr>
      <td>${esc(name)}</td>
      <td class="num">${fmtBytes(usage.free_bytes)} free</td>
      <td class="num">${fmtBytes(usage.total_bytes)}</td>
      <td style="min-width:110px">${pct}%<div class="bar"><span style="width:${pct}%"></span></div></td>
    </tr>`;
  }).join("");
  return card("Storage", `<div class="table-wrap"><table>
    <thead><tr><th>path</th><th class="num">free</th><th class="num">total</th><th>used</th></tr></thead>
    <tbody>${rows}</tbody></table></div>`, badge("mounts", ""));
}

function renderConfig(config) {
  const warnings = [...(config.missing || []).map((item) => `${item} is not set`), ...(config.warnings || [])];
  const body = `<div class="chips">
      <span class="chip${config.ftp_configured ? "" : " warn"}">FTP <b>${config.ftp_configured ? "configured" : "missing"}</b></span>
      <span class="chip${config.github_configured ? "" : " warn"}">GitHub token <b>${config.github_configured ? "configured" : "missing"}</b></span>
      <span class="chip">state dir <b>${config.state_configured ? "configured" : "default"}</b></span>
    </div>` + listWarnings(warnings);
  return card("Configuration", body, badge(warnings.length ? "warnings" : "ok",
    warnings.length ? "warn" : "ok"));
}

function renderRuns(runs) {
  if (!runs.length) {
    els.runs.innerHTML = `<p class="muted">No catalog-update run reports found.</p>`;
    return;
  }
  const rows = runs.map((run) => {
    const error = run.error
      ? `${run.error.stage || "run"}: ${run.error.message || ""}`
      : "";
    const actions = Object.entries(run.actions || {})
      .map(([key, value]) => `${key}=${value}`)
      .join(", ");
    return `<tr title="${esc(actions)}">
      <td>${fmtTime(run.started_at)}</td>
      <td>${badge(run.status || "unknown", statusKind(run.status))}</td>
      <td>${fmtDuration(run.started_at, run.finished_at)}</td>
      <td>${esc(actions || "–")}</td>
      <td>${error ? `<span class="badge badge-bad">${esc(error)}</span>` : ""}</td>
    </tr>`;
  }).join("");
  els.runs.innerHTML = `<table>
    <thead><tr><th>started</th><th>status</th><th>duration</th><th>actions</th><th>error</th></tr></thead>
    <tbody>${rows}</tbody></table>`;
}

function render(status, runs) {
  els.version.textContent = `v${status.tool_version || "?"}`;
  els.updated.textContent = `updated ${new Date().toLocaleTimeString()}`;
  const cards = [
    renderSync(status.sync || {}),
    renderGameinfo(status.gameinfo || {}),
    renderFullIndex(status.full_index || {}),
    renderCrews(status.crews || {}),
    renderPublish(status.publish || {}),
    renderScreenshots(status.screenshots || {}),
    renderStorage(status.storage || {}),
    renderConfig(status.config || {}),
  ];
  els.cards.innerHTML = cards.join("");
  renderRuns(runs || []);
}

async function fetchJson(path) {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return response.json();
}

async function refresh() {
  try {
    const [status, runsPayload] = await Promise.all([
      fetchJson("/api/status"),
      fetchJson("/api/runs?limit=10"),
    ]);
    els.banner.hidden = true;
    render(status, runsPayload.runs || []);
  } catch (error) {
    els.banner.hidden = false;
    els.banner.textContent = `Status could not be loaded: ${error.message}`;
  }
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh();
});

refresh();
setInterval(() => {
  if (!document.hidden) refresh();
}, REFRESH_MS);
