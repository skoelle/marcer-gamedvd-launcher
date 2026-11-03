/* Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
   Licensed under the MIT License. See LICENSE file in project root. */

const IDLE_REFRESH_MS = 5000;
const RUNNING_REFRESH_MS = 2000;
const TOKEN_KEY = "marcerPipelineToken";
const STATUS_ORDER = [
  "done", "desktop", "no_usable_shots", "pending",
  "error", "interrupted", "timeout", "skipped_disk_n", "unknown",
];

const els = {
  cards: document.getElementById("cards"),
  rightColumn: document.getElementById("right-column"),
  screenshots: document.getElementById("screenshots"),
  jobs: document.getElementById("jobs"),
  runs: document.getElementById("runs"),
  banner: document.getElementById("banner"),
  version: document.getElementById("version"),
  updated: document.getElementById("updated"),
  startFull: document.getElementById("start-full"),
  startDry: document.getElementById("start-dry"),
  cancelJob: document.getElementById("cancel-job"),
  tokenField: document.getElementById("token-field"),
  token: document.getElementById("token"),
  actionHint: document.getElementById("action-hint"),
  jobPanel: document.getElementById("job-panel"),
  jobStatus: document.getElementById("job-status"),
  jobMeta: document.getElementById("job-meta"),
  jobLog: document.getElementById("job-log"),
};

let refreshTimer = null;
let refreshInFlight = false;
let currentJob = null;
let bannerSource = "";

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
  if (["pending", "dirty", "dry-run", "degraded", "running", "cancelling", "cancelled"].includes(status)) return "warn";
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
  const stateLabel = config.state_source === "env"
    ? "MARCER_STATE_DIR"
    : config.state_source === "data"
      ? "DATA/state"
      : "missing";
  const body = `<div class="chips">
      <span class="chip${config.ftp_configured ? "" : " warn"}">FTP <b>${config.ftp_configured ? "configured" : "missing"}</b></span>
      <span class="chip${config.github_configured ? "" : " warn"}">GitHub token <b>${config.github_configured ? "configured" : "missing"}</b></span>
      <span class="chip${config.state_source === "missing" ? " warn" : ""}">state dir <b>${stateLabel}</b></span>
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

function getToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || "";
  } catch {
    return "";
  }
}

function saveToken() {
  try {
    localStorage.setItem(TOKEN_KEY, els.token.value.trim());
  } catch {
    /* localStorage can be unavailable in private mode */
  }
}

function apiHeaders() {
  const headers = { "Content-Type": "application/json" };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

async function postJson(path, payload) {
  const response = await fetch(path, {
    method: "POST",
    headers: apiHeaders(),
    body: JSON.stringify(payload || {}),
  });
  let data = {};
  try {
    data = await response.json();
  } catch {
    data = {};
  }
  if (!response.ok) {
    const error = new Error(data.error || `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function setBanner(message, source = "status") {
  if (!message) {
    els.banner.hidden = true;
    els.banner.textContent = "";
    bannerSource = "";
    return;
  }
  els.banner.hidden = false;
  els.banner.textContent = message;
  bannerSource = source;
}

function setHint(message) {
  els.actionHint.textContent = message;
}

function updateTokenField(required) {
  els.tokenField.hidden = !required;
  if (!required) {
    try {
      localStorage.removeItem(TOKEN_KEY);
    } catch {
      /* ignore unavailable storage */
    }
    els.token.value = "";
  }
}

function handleAuthError(error) {
  if (error.status === 401) {
    updateTokenField(true);
    setBanner("Token missing or invalid. Enter it in the Token field.", "action");
    els.token.focus();
    return true;
  }
  return false;
}

function jobErrorText(error) {
  if (!error) return "";
  return `${error.stage || "run"}: ${error.message || ""}`;
}

function jobDuration(job) {
  return fmtDuration(job.started_at, job.finished_at || new Date().toISOString());
}

function renderJobs(jobs) {
  if (!jobs || !jobs.length) {
    els.jobs.innerHTML = `<p class="muted">No pipeline jobs yet.</p>`;
    return;
  }
  const rows = jobs.map((job) => {
    const error = jobErrorText(job.error);
    return `<tr>
      <td>${fmtTime(job.started_at)}</td>
      <td>${esc(job.mode || "–")}</td>
      <td>${badge(job.status || "unknown", statusKind(job.status))}</td>
      <td>${esc(job.stage || "–")}</td>
      <td>${fmtDuration(job.started_at, job.finished_at)}</td>
      <td class="num">${esc(job.exit_code ?? "–")}</td>
      <td>${error ? `<span class="badge badge-bad">${esc(error)}</span>` : ""}</td>
    </tr>`;
  }).join("");
  els.jobs.innerHTML = `<table>
    <thead><tr><th>started</th><th>mode</th><th>status</th><th>stage</th>
    <th>duration</th><th class="num">exit</th><th>error</th></tr></thead>
    <tbody>${rows}</tbody></table>`;
}

async function refreshJobLog(jobId) {
  const log = els.jobLog;
  const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  try {
    const data = await fetchJson(`/api/jobs/${encodeURIComponent(jobId)}/log?tail=200`);
    log.textContent = (data.lines || []).join("\n");
    if (atBottom) log.scrollTop = log.scrollHeight;
  } catch {
    /* a job can finish between the status and log request */
  }
}

function renderJob(job) {
  currentJob = job || null;
  const running = !!job && ["running", "cancelling"].includes(job.status);
  els.startFull.disabled = running;
  els.startDry.disabled = running;
  els.cancelJob.hidden = !running;
  if (!job) {
    els.jobPanel.hidden = true;
    els.jobLog.textContent = "";
    return;
  }
  els.jobPanel.hidden = false;
  els.jobStatus.innerHTML = badge(job.status || "unknown", statusKind(job.status));
  els.jobMeta.innerHTML = kv([
    ["mode", job.mode || "–"],
    ["stage", job.stage || "–"],
    ["started", fmtTime(job.started_at)],
    ["duration", jobDuration(job)],
    ["exit", job.exit_code ?? "–"],
    ["error", jobErrorText(job.error) || "–"],
  ]);
  refreshJobLog(job.id);
}

async function startJob(mode) {
  const label = mode === "dry-run" ? "Dry run" : "Full catalog update";
  if (mode !== "dry-run" && !window.confirm(
    "Start a full catalog update now? This runs FTP sync, gameinfo, full index, crews and publish."
  )) {
    return;
  }
  setBanner("");
  setHint(`Starting ${label}…`);
  els.startFull.disabled = true;
  els.startDry.disabled = true;
  try {
    const data = await postJson("/api/run", { mode });
    setHint(`Job ${data.job.id} started.`);
    await refresh();
  } catch (error) {
    setHint("");
    if (!handleAuthError(error)) {
      setBanner(`Cannot start job: ${error.message}`, "action");
    }
    els.startFull.disabled = false;
    els.startDry.disabled = false;
  }
}

async function cancelCurrentJob() {
  if (!currentJob) return;
  if (!window.confirm(`Cancel job ${currentJob.id}?`)) return;
  setBanner("");
  setHint("Cancellation requested…");
  try {
    await postJson("/api/cancel", { id: currentJob.id });
    await refresh();
  } catch (error) {
    if (!handleAuthError(error)) {
      setBanner(`Cannot cancel job: ${error.message}`, "action");
    }
  }
}

function scheduleRefresh(delay) {
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => {
    if (!document.hidden) {
      refresh();
    } else {
      scheduleRefresh(IDLE_REFRESH_MS);
    }
  }, delay);
}

function render(status, runs, jobsPayload) {
  els.version.textContent = `v${status.tool_version || "?"}`;
  els.updated.textContent = `updated ${new Date().toLocaleTimeString()}`;
  updateTokenField(!!(status.config && status.config.pipeline_token_required));
  els.cards.innerHTML = [
    renderSync(status.sync || {}),
    `<div class="card-stack">
      ${renderPublish(status.publish || {})}
      ${renderConfig(status.config || {})}
    </div>`,
    renderStorage(status.storage || {}),
  ].join("");
  els.rightColumn.innerHTML = [
    renderGameinfo(status.gameinfo || {}),
    renderFullIndex(status.full_index || {}),
    renderCrews(status.crews || {}),
  ].join("");
  els.screenshots.innerHTML = renderScreenshots(status.screenshots || {});
  renderJobs((jobsPayload && jobsPayload.jobs) || []);
  renderJob((jobsPayload && jobsPayload.current) || null);
  renderRuns(runs || []);
}

async function fetchJson(path) {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return response.json();
}

async function refresh() {
  if (refreshInFlight) return;
  refreshInFlight = true;
  let delay = IDLE_REFRESH_MS;
  try {
    const [status, runsPayload, jobsPayload] = await Promise.all([
      fetchJson("/api/status"),
      fetchJson("/api/runs?limit=10"),
      fetchJson("/api/jobs?limit=10"),
    ]);
    if (bannerSource === "status") setBanner("");
    render(status, runsPayload.runs || [], jobsPayload);
    const running = jobsPayload.current
      && ["running", "cancelling"].includes(jobsPayload.current.status);
    delay = running ? RUNNING_REFRESH_MS : IDLE_REFRESH_MS;
  } catch (error) {
    setBanner(`Status could not be loaded: ${error.message}`);
  } finally {
    refreshInFlight = false;
    scheduleRefresh(delay);
  }
}

els.token.value = getToken();
els.token.addEventListener("input", saveToken);
els.startFull.addEventListener("click", () => startJob("full"));
els.startDry.addEventListener("click", () => startJob("dry-run"));
els.cancelJob.addEventListener("click", cancelCurrentJob);

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh();
});

refresh();
