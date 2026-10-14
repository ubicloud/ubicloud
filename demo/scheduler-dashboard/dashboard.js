"use strict";

// Live side-by-side view of two control planes' scheduler metrics.
// The payload format is specified in METRICS.md.
(() => {
  const SIDES = ["current", "central"];
  const SIDE_INFO = {
    current: { name: "Current", sub: "Each runner polls; allocator retries on a 5–30s backoff", color: "var(--current)" },
    central: { name: "Central", sub: "One queue, dispatched when capacity changes", color: "var(--central)" },
  };
  const STAGES = [
    { key: "waiting_admission", label: "Waiting: admission", color: "var(--stage-admission)" },
    { key: "waiting_capacity", label: "Waiting: capacity", color: "var(--stage-capacity)" },
    { key: "booting", label: "Booting", color: "var(--stage-booting)" },
    { key: "idle", label: "Idle", color: "var(--stage-idle)" },
  ];
  const WAIT_STATS = {
    p50: { label: "p50", path: "waiting.p50_seconds" },
    p95: { label: "p95", path: "waiting.p95_seconds" },
    oldest: { label: "Oldest", path: "waiting.oldest_seconds" },
  };
  const SIZES = [2, 4, 8, 16, 30];
  // What the by-size panel plots for each runner size, from `by_vcpus`.
  // value(sample, size) returns null when a side doesn't report the field.
  const bucket = (s, size) => s.m.by_vcpus.find((x) => x.vcpus === size);
  const SIZE_STATS = {
    oldest: {
      kind: "duration", fmt: (v) => fmtDur(v), value: (s, size) => bucket(s, size)?.oldest_seconds ?? null,
      note: "Large runners starving shows as the 16 and 30 vCPU charts climbing while the small ones stay flat.",
    },
    waiting: {
      kind: "count", fmt: (v) => fmtInt(v), value: (s, size) => bucket(s, size)?.waiting ?? null,
      note: "How many requests of each size are waiting for a host.",
    },
    vcpus: {
      kind: "count", fmt: (v) => fmtInt(v),
      value: (s, size) => (bucket(s, size) ? bucket(s, size).waiting * size : null),
      note: "Waiting requests × size: how much of the backlog each size really is.",
    },
    placed: {
      kind: "count", fmt: (v) => fmtRate(v), field: "counters.allocated_by_vcpus",
      value: (s, size) => s.sizeRates?.[size]?.allocations ?? null,
      note: "Small runners being favored shows as 2 and 4 vCPU placements continuing while 16 and 30 drop to zero.",
    },
    slots: {
      kind: "count", fmt: (v) => fmtInt(v), field: "fleet.free_slots_by_vcpus",
      value: (s, size) => s.m.fleet.free_slots_by_vcpus?.[size] ?? null,
      note: "How many more runners of each size fit right now. Plenty of small slots but none for 30 vCPU means fragmentation.",
    },
  };
  const AGE_LABELS = ["≤10s", "≤30s", "≤1m", "≤2m", "≤5m", "≤10m", "≤30m", "≤1h", ">1h"];
  const SEVERITY_COLOR = { page: "var(--critical)", monitor: "var(--warning)" };
  const DEFAULTS = { current: "/current/scheduler/metrics", central: "/central/scheduler/metrics", interval: 1000 };
  const STORAGE_KEY = "scheduler-dashboard";
  const RATE_WINDOW_MS = 20000;
  const BURST_MIN = 25; // new requests in one poll that mark a burst
  const BURST_MERGE_MS = 15000;
  const HISTORY_MS = 16 * 60 * 1000;
  const ALERT_SHOW_FRACTION = 0.25; // draw a threshold in-scale once data reaches this share of it
  const NS = "http://www.w3.org/2000/svg";

  // ---------------------------------------------------------------- config

  function readStored() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}") || {};
    } catch {
      return {};
    }
  }
  function writeStored(patch) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...readStored(), ...patch }));
    } catch {
      // Storage can be unavailable (private windows); settings then last for the page only.
    }
  }

  const params = new URLSearchParams(location.search);
  const stored = readStored();
  const cfg = {};
  for (const k of Object.keys(DEFAULTS)) cfg[k] = params.get(k) ?? stored[k] ?? DEFAULTS[k];
  cfg.interval = Math.max(250, Number(cfg.interval) || DEFAULTS.interval);

  const state = {
    windowMs: [120000, 300000, 900000].includes(stored.windowMs) ? stored.windowMs : 300000,
    waitStat: WAIT_STATS[stored.waitStat] ? stored.waitStat : "oldest",
    sizeStat: SIZE_STATS[stored.sizeStat] ? stored.sizeStat : "oldest",
    paused: false,
    frozenEnd: null,
    hover: null, // {t, chartId}
    markers: [], // {t, last, n: {side: count}}
    sides: {},
  };
  for (const s of SIDES) state.sides[s] = { hist: [], error: null, lastOk: 0 };
  // Real endpoints the serving process proxies each default path to (GET /config).
  let upstreams = {};

  // ---------------------------------------------------------------- format

  const fmtInt = (v) => (v == null ? "—" : Math.round(v).toLocaleString());
  const fmtRate = (v) => (v == null ? "—" : v < 10 ? v.toFixed(1) : Math.round(v).toLocaleString());
  const fmtPct = (v) => (v == null ? "—" : `${Math.round(v * 100)}%`);
  function fmtDur(s) {
    if (s == null || Number.isNaN(s)) return "—";
    if (s < 10) return `${s.toFixed(1)}s`;
    if (s < 60) return `${Math.round(s)}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m ${String(Math.round(s % 60)).padStart(2, "0")}s`;
    return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
  }
  function fmtDurAxis(s) {
    if (s < 60) return `${s}s`;
    if (s < 3600) {
      const m = s / 60;
      return Number.isInteger(m) ? `${m}m` : `${m.toFixed(1)}m`;
    }
    const h = s / 3600;
    return Number.isInteger(h) ? `${h}h` : `${h.toFixed(1)}h`;
  }
  const fmtAgo = (ms) => (ms < 1000 ? "now" : `−${fmtDurAxis(Math.round(ms / 1000))}`);

  // ---------------------------------------------------------------- data

  function validate(m) {
    const ok = m && m.stages && m.waiting && m.counters && m.latency && m.fleet && Array.isArray(m.by_vcpus);
    if (!ok) throw new Error("payload does not match METRICS.md");
  }

  // Read a dotted metric path; fleet.utilization is derived.
  function metric(sample, path) {
    if (!sample) return null;
    if (path === "fleet.utilization") {
      const f = sample.m.fleet;
      return f.vcpus_total ? f.vcpus_used / f.vcpus_total : null;
    }
    let v = sample.m;
    for (const k of path.split(".")) v = v?.[k];
    return typeof v === "number" ? v : null;
  }

  // Per-minute rate of a counter, read by `get` from a payload, over about
  // RATE_WINDOW_MS of history.
  function rate(hist, sample, get) {
    let ref = null;
    for (let i = hist.length - 1; i >= 0; i--) {
      ref = hist[i];
      if (sample.gen - ref.gen >= RATE_WINDOW_MS) break;
    }
    if (!ref) return null;
    const dt = (sample.gen - ref.gen) / 1000;
    const now = get(sample.m);
    const then = get(ref.m);
    if (typeof now !== "number" || typeof then !== "number") return null;
    const d = now - then;
    if (dt < 0.5 || d < 0) return null; // too soon, or the counter reset
    return (d / dt) * 60;
  }

  function ingest(side, t, m) {
    const S = state.sides[side];
    const prev = S.hist[S.hist.length - 1];
    const sample = { t, m, gen: Date.parse(m.generated_at) || t };
    if (prev && prev.gen === sample.gen) return; // same snapshot polled twice
    sample.rates = {
      arrivals: rate(S.hist, sample, (x) => x.counters.requests_received_total),
      allocations: rate(S.hist, sample, (x) => x.counters.allocated_total),
      checks: rate(S.hist, sample, (x) => x.counters.scheduling_checks_total),
    };
    sample.sizeRates = Object.fromEntries(SIZES.map((size) => [size, {
      allocations: rate(S.hist, sample, (x) => x.counters.allocated_by_vcpus?.[size]),
    }]));
    if (prev) {
      const d = m.counters.requests_received_total - prev.m.counters.requests_received_total;
      if (d >= BURST_MIN) noteBurst(side, t, d);
    }
    S.hist.push(sample);
  }

  function noteBurst(side, t, d) {
    const last = state.markers[state.markers.length - 1];
    if (last && t - last.last <= BURST_MERGE_MS) {
      last.n[side] = (last.n[side] || 0) + d;
      last.last = t;
    } else {
      state.markers.push({ t, last: t, n: { [side]: d } });
    }
  }
  const markerSize = (mk) => Math.max(...SIDES.map((s) => mk.n[s] || 0));

  function prune(now) {
    const cutoff = now - HISTORY_MS;
    for (const s of SIDES) {
      const h = state.sides[s].hist;
      let i = 0;
      while (i < h.length && h[i].t < cutoff) i++;
      if (i) h.splice(0, i);
    }
    state.markers = state.markers.filter((mk) => mk.t >= cutoff);
  }

  function latestT() {
    return Math.max(0, ...SIDES.map((s) => state.sides[s].hist.at(-1)?.t || 0)) || Date.now();
  }
  const viewEnd = () => (state.paused ? state.frozenEnd : latestT());

  // Index of the last sample at or before t (or -1).
  function indexAtOrBefore(hist, t) {
    let lo = 0;
    let hi = hist.length - 1;
    let ans = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (hist[mid].t <= t) {
        ans = mid;
        lo = mid + 1;
      } else hi = mid - 1;
    }
    return ans;
  }
  function nearest(hist, t) {
    const i = indexAtOrBefore(hist, t);
    const a = hist[i];
    const b = hist[i + 1];
    if (!a) return b || null;
    if (!b) return a;
    return t - a.t <= b.t - t ? a : b;
  }
  function sampleAt(side) {
    const h = state.sides[side].hist;
    return h[indexAtOrBefore(h, viewEnd())] || null;
  }
  const gapMs = () => Math.max(cfg.interval * 3, 4000);

  function sideStatus(side) {
    const S = state.sides[side];
    if (!S.lastOk) return S.error ? "error" : "connecting";
    if (Date.now() - S.lastOk <= cfg.interval * 3 + 500) return "live";
    return S.error ? "error" : "stale";
  }

  // Alerts a side declares (METRICS.md "Alerts"), from its latest payload.
  const alertsOf = (side) => sampleAt(side)?.m.alerts || [];

  // ---------------------------------------------------------------- polling

  async function fetchSide(side) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), Math.max(1500, cfg.interval * 2));
    try {
      const r = await fetch(cfg[side], { signal: ctl.signal, cache: "no-store" });
      if (!r.ok) {
        const detail = await r.json().then((b) => b.error).catch(() => null);
        throw new Error(detail || `HTTP ${r.status}`);
      }
      return await r.json();
    } finally {
      clearTimeout(timer);
    }
  }

  // Where a side's data really comes from, for the settings panel and errors.
  function sourceOf(side) {
    if (cfg[side] !== DEFAULTS[side]) return cfg[side];
    return upstreams[side] ? `${upstreams[side]} (via this server)` : "simulated by this server";
  }

  // Start with what the serving process recorded before this page opened,
  // so a reload or a late viewer doesn't begin with empty charts.
  async function loadHistory() {
    const sides = SIDES.filter((side) => cfg[side] === DEFAULTS[side]);
    if (!sides.length) return;
    try {
      const r = await fetch(`/history?seconds=${Math.round(HISTORY_MS / 1000)}`, { cache: "no-store" });
      if (!r.ok) return;
      const { now, samples } = await r.json();
      const offset = now - Date.now(); // server clock vs this browser's
      const merged = sides.flatMap((side) => (samples[side] || []).map(([t, m]) => ({ side, t: t - offset, m })));
      merged.sort((a, b) => a.t - b.t);
      for (const { side, t, m } of merged) {
        try {
          validate(m);
          ingest(side, t, m);
        } catch {
          // Skip a malformed historical sample; live polling reports errors.
        }
      }
    } catch {
      // No history available; charts fill as polls arrive.
    }
  }

  async function loadServerConfig() {
    try {
      const r = await fetch("/config", { cache: "no-store" });
      if (r.ok) upstreams = (await r.json()).upstreams || {};
      // A real endpoint saved by hand earlier is the one this server proxies:
      // go through the server so it also works over HTTPS.
      for (const side of SIDES) if (upstreams[side] && cfg[side] === upstreams[side]) cfg[side] = DEFAULTS[side];
    } catch {
      // Opened from a static server without /config; the defaults still work.
    }
  }

  let pollTimer = null;
  async function poll() {
    const started = Date.now();
    const results = await Promise.allSettled(SIDES.map(fetchSide));
    const t = Date.now(); // one timestamp for both, so the columns line up
    results.forEach((r, i) => {
      const S = state.sides[SIDES[i]];
      try {
        if (r.status !== "fulfilled") throw r.reason;
        validate(r.value);
        ingest(SIDES[i], t, r.value);
        S.lastOk = t;
        S.error = null;
      } catch (e) {
        S.error = e?.name === "AbortError" ? "timed out" : e?.message || "request failed";
      }
    });
    prune(t);
    render();
    pollTimer = setTimeout(poll, Math.max(0, cfg.interval - (Date.now() - started)));
  }

  // ---------------------------------------------------------------- svg helpers

  function el(tag, attrs, parent) {
    const node = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) node.setAttribute(k, v);
    if (parent) parent.appendChild(node);
    return node;
  }
  function text(parent, x, y, str, attrs) {
    const node = el("text", { x, y, ...attrs }, parent);
    node.textContent = str;
    return node;
  }

  function niceScale(maxVal, kind) {
    if (kind === "pct") return { max: 1, ticks: [0, 0.25, 0.5, 0.75, 1] };
    let max = maxVal > 0 ? maxVal : kind === "duration" ? 30 : 4;
    let step;
    if (kind === "duration") {
      step = [1, 2, 5, 10, 15, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 3600, 7200].find((s) => max / s <= 4) || 3600 * Math.ceil(max / 14400);
    } else {
      const raw = max / 4;
      const mag = 10 ** Math.floor(Math.log10(raw));
      step = [1, 2, 5, 10].map((x) => x * mag).find((x) => x >= raw);
      if (step < 1 && maxVal >= 1) step = 1;
    }
    max = Math.ceil(max / step - 1e-9) * step;
    const ticks = [];
    for (let v = 0; v <= max + 1e-9; v += step) ticks.push(+v.toFixed(6));
    return { max, ticks };
  }
  const valueFmt = (kind, v) => {
    if (kind === "duration") return v % 60 === 0 ? fmtDurAxis(v) : fmtDur(v);
    return kind === "pct" ? fmtPct(v) : fmtRate(v);
  };
  const tickLabel = (kind, v) => (kind === "duration" ? fmtDurAxis(v) : kind === "pct" ? fmtPct(v) : fmtRate(v).replace(/\.0$/, ""));

  // Break a sample list into contiguous runs wherever polls were missed.
  function runs(samples, gap) {
    const out = [];
    let cur = [];
    for (const s of samples) {
      if (cur.length && s.t - cur[cur.length - 1].t > gap) {
        out.push(cur);
        cur = [];
      }
      cur.push(s);
    }
    if (cur.length) out.push(cur);
    return out;
  }
  const pathOf = (pts) => pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join("");

  function visibleSamples(side, x0, x1) {
    const h = state.sides[side].hist;
    const i = Math.max(0, indexAtOrBefore(h, x0));
    const j = indexAtOrBefore(h, x1);
    return j < 0 ? [] : h.slice(i, j + 1);
  }

  // Frame shared by every time chart: grid, y ticks, relative x ticks, burst
  // markers, and paging/monitoring threshold lines.
  function frame(c, scale, x0, x1, H, m) {
    const W = Math.max(280, c.host.clientWidth);
    const iw = W - m.l - m.r;
    const ih = H - m.t - m.b;
    const X = (t) => m.l + ((t - x0) / (x1 - x0)) * iw;
    const Y = (v) => m.t + ih - (Math.min(Math.max(v, 0), scale.max) / scale.max) * ih;
    const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, height: H, role: "img", "aria-label": c.aria });
    const clipId = `clip-${c.id}`;
    el("rect", { x: m.l, y: 0, width: iw, height: m.t + ih + 1 }, el("clipPath", { id: clipId }, el("defs", {}, svg)));
    if (c.kind !== "heatmap") {
      for (const v of scale.ticks) {
        const y = Y(v);
        el("line", { x1: m.l, x2: m.l + iw, y1: y, y2: y, style: `stroke: ${v === 0 ? "var(--axis)" : "var(--grid)"}`, "stroke-width": 1 }, svg);
        text(svg, m.l - 6, y + 3.5, tickLabel(c.scaleKind, v), { "text-anchor": "end" });
      }
    }
    const span = x1 - x0;
    const step = [15000, 30000, 60000, 120000, 180000, 300000].find((s) => span / s <= 5) || 300000;
    for (let off = 0; off <= span + 1; off += step) text(svg, X(x1 - off), H - 6, fmtAgo(off), { "text-anchor": off === 0 ? "end" : "middle" });
    for (const mk of state.markers) {
      if (mk.t < x0 || mk.t > x1) continue;
      const x = X(mk.t);
      el("line", { x1: x, x2: x, y1: m.t - 4, y2: m.t + ih, style: "stroke: var(--ink-2)", "stroke-width": 1, opacity: 0.45 }, svg);
      if (!c.compact) text(svg, x + 4, m.t - 6, `+${fmtInt(markerSize(mk))} burst`, { class: "marker" });
    }
    const plot = el("g", { "clip-path": `url(#${clipId})` }, svg);
    c.geom = { m, iw, ih, x0, x1, W };
    return { svg, plot, X, Y, W, iw, ih };
  }

  function chartAlerts(c) {
    if (!c.alertMetrics) return [];
    const seen = new Map();
    for (const side of new Set(c.series.map((s) => s.side))) {
      for (const a of alertsOf(side)) {
        if (c.alertMetrics.includes(a.metric)) seen.set(`${a.id}|${a.threshold}`, a);
      }
    }
    return [...seen.values()];
  }

  // Threshold lines drawn over the data; thresholds far above the data get a
  // note in the corner instead of squashing the chart.
  function drawAlerts(c, svg, scale, m, iw, Y) {
    const offScale = [];
    const inScale = [];
    for (const a of chartAlerts(c)) (a.threshold > scale.max ? offScale : inScale).push(a);
    // Top line first. A label sits just above its line, or just below it
    // when the line hugs the top of the plot, and is pushed down until it
    // clears the label before it.
    inScale.sort((a, b) => b.threshold - a.threshold);
    let prevLabelY = -Infinity;
    for (const a of inScale) {
      const y = Y(a.threshold);
      const color = SEVERITY_COLOR[a.severity] || "var(--warning)";
      el("line", { x1: m.l, x2: m.l + iw, y1: y, y2: y, style: `stroke: ${color}`, "stroke-width": 2 }, svg);
      const ly = Math.max(y - 5 >= m.t + 10 ? y - 5 : y + 14, prevLabelY + 14);
      prevLabelY = ly;
      const label = text(svg, m.l + 6, ly, "", { class: "alert" });
      el("tspan", { style: `fill: ${color}` }, label).textContent = a.severity === "page" ? "▲ " : "● ";
      el("tspan", {}, label).textContent = `${a.label} · ${valueFmt(c.scaleKind, a.threshold)}`;
    }
    // Thresholds far above the data are listed above the chart instead of
    // squashing it.
    c.notes.replaceChildren();
    for (const a of offScale) {
      const span = document.createElement("span");
      const icon = document.createElement("b");
      icon.style.color = SEVERITY_COLOR[a.severity] || "var(--warning)";
      icon.textContent = a.severity === "page" ? "▲" : "●";
      span.append(icon, document.createTextNode(` ${a.label} at ${valueFmt(c.scaleKind, a.threshold)}, above chart`));
      c.notes.appendChild(span);
    }
  }

  // ---------------------------------------------------------------- charts

  const charts = [];
  const groups = {};

  function addChart(hostId, opts) {
    const host = document.getElementById(hostId);
    const notes = document.createElement("div");
    notes.className = "alert-notes";
    const tip = document.createElement("div");
    tip.className = "tip";
    host.append(notes, tip);
    const c = { id: hostId, host, notes, tip, kind: "lines", height: 180, scaleKind: "count", ...opts };
    charts.push(c);
    (groups[c.group || c.id] ||= []).push(c);

    let raf = 0;
    host.addEventListener("pointermove", (e) => {
      const g = c.geom;
      if (!g) return;
      const px = e.clientX - host.getBoundingClientRect().left;
      if (px < g.m.l || px > g.m.l + g.iw) {
        if (state.hover?.chartId === c.id) setHover(null);
        return;
      }
      const t = g.x0 + ((px - g.m.l) / g.iw) * (g.x1 - g.x0);
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => setHover({ t, chartId: c.id }));
    });
    host.addEventListener("pointerleave", () => setHover(null));
    return c;
  }

  function setHover(h) {
    state.hover = h;
    renderCharts();
  }

  function dataMax(c, x0, x1) {
    // Only samples inside the window count; visibleSamples also returns the
    // one before it, which can hold a much larger, no longer visible value.
    const inView = (side) => visibleSamples(side, x0, x1).filter((s) => s.t >= x0);
    let max = 0;
    if (c.kind === "heatmap") {
      for (const s of inView(c.side)) max = Math.max(max, ...(s.m.waiting.age_histogram?.counts || [0]));
      return max;
    }
    if (c.kind === "stacked") {
      for (const s of inView(c.series[0].side)) max = Math.max(max, c.series.reduce((a, se) => a + (se.value(s) || 0), 0));
      return max;
    }
    for (const se of c.series) {
      for (const s of inView(se.side)) max = Math.max(max, se.value(s) || 0);
    }
    return max;
  }

  function groupScale(list, x0, x1) {
    const kind = list[0].scaleKind;
    const dmax = Math.max(0, ...list.map((c) => dataMax(c, x0, x1)));
    if (kind === "pct" || list[0].kind === "heatmap") return { ...niceScale(dmax, kind), dataMax: dmax };
    // Pull a threshold into view once the data gets close enough to matter.
    const near = list.flatMap(chartAlerts).map((a) => a.threshold).filter((t) => dmax >= t * ALERT_SHOW_FRACTION);
    return { ...niceScale(Math.max(dmax, ...near.map((t) => t * 1.08)), kind), dataMax: dmax };
  }

  function renderLines(c, scale, x0, x1) {
    const m = c.margin || { l: 44, r: 58, t: 18, b: 22 };
    const f = frame(c, scale, x0, x1, c.height, m);
    const { svg, plot, X, Y } = f;
    const gap = gapMs();
    const ends = [];

    if (c.kind === "stacked") {
      const samples = visibleSamples(c.series[0].side, x0, x1);
      for (const run of runs(samples, gap)) {
        let lower = run.map(() => 0);
        for (const se of c.series) {
          const upper = run.map((s, k) => lower[k] + (se.value(s) || 0));
          const top = run.map((s, k) => [X(s.t), Y(upper[k])]);
          const bottom = run.map((s, k) => [X(s.t), Y(lower[k])]).reverse();
          el("path", { d: `${pathOf(top)}${pathOf(bottom).replace(/^M/, "L")}Z`, style: `fill: ${se.color}` }, plot);
          // 2px surface gap along each layer's top edge.
          if (upper.some((v, k) => v > lower[k])) el("path", { d: pathOf(top), fill: "none", style: "stroke: var(--surface)", "stroke-width": 2, "stroke-linejoin": "round" }, plot);
          lower = upper;
        }
      }
      const last = samples.at(-1);
      if (last && x1 - last.t <= gap) {
        const total = c.series.reduce((a, se) => a + (se.value(last) || 0), 0);
        ends.push({ y: Y(total), label: fmtInt(total) });
      }
    } else {
      drawOverlapOutline(c, x0, x1, X, Y, gap, plot);
      for (const se of c.series) {
        const samples = visibleSamples(se.side, x0, x1).filter((s) => se.value(s) != null);
        for (const run of runs(samples, gap)) {
          if (se.lo) {
            // Band between lo and value (e.g. p50–p95), a wash of the series hue.
            const top = run.map((s) => [X(s.t), Y(se.value(s))]);
            const bottom = run.map((s) => [X(s.t), Y(se.lo(s) || 0)]).reverse();
            el("path", { d: `${pathOf(top)}${pathOf(bottom).replace(/^M/, "L")}Z`, style: `fill: ${se.color}`, "fill-opacity": 0.22 }, plot);
            continue;
          }
          const pts = run.map((s) => [X(s.t), Y(se.value(s))]);
          if (c.wash) el("path", { d: `${pathOf(pts)}L${pts.at(-1)[0].toFixed(1)},${Y(0)}L${pts[0][0].toFixed(1)},${Y(0)}Z`, style: `fill: ${se.color}`, "fill-opacity": 0.1 }, plot);
          el("path", { d: pathOf(pts), fill: "none", style: `stroke: ${se.color}`, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }, plot);
        }
        const last = samples.at(-1);
        if (!se.lo && last && x1 - last.t <= gap) {
          const v = se.value(last);
          ends.push({ y: Y(v), x: X(last.t), label: se.fmt(v), color: se.color });
        }
      }
    }

    drawAlerts(c, svg, scale, m, f.iw, Y);

    // End dots and direct value labels, nudged apart so they never collide.
    ends.sort((a, b) => a.y - b.y);
    for (let i = 0; i < ends.length; i++) ends[i].ly = Math.max(ends[i].y, i ? ends[i - 1].ly + 13 : -Infinity);
    // If that pushed labels below the baseline, stack them back up from it.
    const bottom = m.t + f.ih;
    for (let i = ends.length - 1; i >= 0; i--) ends[i].ly = Math.min(ends[i].ly, i === ends.length - 1 ? bottom : ends[i + 1].ly - 13);
    for (const e of ends) {
      if (e.color) el("circle", { cx: e.x, cy: e.y, r: 4, style: `fill: ${e.color}; stroke: var(--surface)`, "stroke-width": 2 }, svg);
      text(svg, f.W - m.r + 8, (e.ly ?? e.y) + 4, e.label, { class: "end" });
    }

    // Crosshair, synced across every time chart.
    const hv = state.hover;
    let tipShown = false;
    if (hv && hv.t >= x0 && hv.t <= x1) {
      const rows = [];
      let xt = null;
      for (const se of c.series) {
        const s = nearest(state.sides[se.side].hist, hv.t);
        if (!s || Math.abs(s.t - hv.t) > gap) continue;
        xt ??= s.t;
        rows.push({ se, v: se.value(s), lo: se.lo ? se.lo(s) : null });
      }
      if (xt != null) {
        const x = X(xt);
        el("line", { x1: x, x2: x, y1: m.t, y2: m.t + f.ih, style: "stroke: var(--ink-2)", "stroke-width": 1, opacity: 0.6 }, svg);
        let acc = 0;
        for (const r of rows) {
          if (r.v == null || r.se.lo) continue;
          acc = c.kind === "stacked" ? acc + r.v : r.v;
          el("circle", { cx: x, cy: Y(acc), r: 4, style: `fill: ${r.se.color}; stroke: var(--surface)`, "stroke-width": 2 }, svg);
        }
        if (hv.chartId === c.id) {
          const tipRows = rows.map((r) => ({ color: r.se.color, value: r.se.lo ? `${r.se.fmt(r.lo)}–${r.se.fmt(r.v)}` : r.se.fmt(r.v), label: r.se.label }));
          if (c.kind === "stacked") {
            tipRows.reverse();
            tipRows.push({ color: null, value: fmtInt(rows.reduce((a, r) => a + (r.v || 0), 0)), label: "Total" });
          }
          showTip(c, x, m.t, fmtAgo(x1 - xt), tipRows);
          tipShown = true;
        }
      }
    }
    if (!tipShown) c.tip.style.display = "none";
    mount(c, svg);
  }

  // In a head-to-head chart, wherever both sides' lines coincide, outline the
  // first side's line underneath so the second doesn't hide it. Lines that
  // are apart stay the same width.
  function drawOverlapOutline(c, x0, x1, X, Y, gap, plot) {
    const [a, b] = c.series;
    if (c.series.length !== 2 || a.side === b.side || a.lo || b.lo) return;
    const other = state.sides[b.side].hist;
    const close = (s) => {
      const o = nearest(other, s.t);
      const va = a.value(s);
      const vb = o && Math.abs(o.t - s.t) <= gap ? b.value(o) : null;
      return va != null && vb != null && Math.abs(Y(va) - Y(vb)) < 2;
    };
    for (const run of runs(visibleSamples(a.side, x0, x1).filter((s) => a.value(s) != null), gap)) {
      let seg = [];
      const flush = () => {
        if (seg.length > 1) el("path", { d: pathOf(seg), fill: "none", style: `stroke: ${a.color}`, "stroke-width": 5, "stroke-linejoin": "round", "stroke-linecap": "round" }, plot);
        seg = [];
      };
      for (const s of run) {
        if (close(s)) seg.push([X(s.t), Y(a.value(s))]);
        else flush();
      }
      flush();
    }
  }

  // Waiting requests by age bucket over time. Each column is one moment;
  // darker cells hold more requests.
  function renderHeatmap(c, scale, x0, x1) {
    const m = { l: 44, r: 58, t: 18, b: 22 };
    const f = frame(c, scale, x0, x1, c.height, m);
    const { svg, plot, X } = f;
    const rows = AGE_LABELS.length;
    const rowH = f.ih / rows;
    AGE_LABELS.forEach((label, i) => {
      if (i % 2 === 0) text(svg, m.l - 6, m.t + f.ih - rowH * i - rowH / 2 + 3.5, label, { "text-anchor": "end" });
    });
    const bins = Math.max(20, Math.min(150, Math.floor(f.iw / 5)));
    const binMs = (x1 - x0) / bins;
    const cellW = f.iw / bins;
    const byBin = new Map();
    for (const s of visibleSamples(c.side, x0, x1)) {
      if (s.t < x0) continue;
      byBin.set(Math.min(bins - 1, Math.floor((s.t - x0) / binMs)), s); // last sample in each bin
    }
    const max = Math.max(1, scale.dataMax);
    for (const [bin, s] of byBin) {
      (s.m.waiting.age_histogram?.counts || []).forEach((n, i) => {
        if (!n) return;
        el("rect", {
          x: (m.l + bin * cellW).toFixed(1), y: (m.t + f.ih - rowH * (i + 1) + 1).toFixed(1),
          width: Math.max(1, cellW - 1).toFixed(1), height: Math.max(1, rowH - 2).toFixed(1),
          style: `fill: ${c.color}`, "fill-opacity": (0.12 + 0.88 * Math.sqrt(n / max)).toFixed(3),
        }, plot);
      });
    }
    const hv = state.hover;
    let tipShown = false;
    if (hv && hv.t >= x0 && hv.t <= x1) {
      const s = nearest(state.sides[c.side].hist, hv.t);
      if (s && Math.abs(s.t - hv.t) <= gapMs()) {
        const x = X(s.t);
        el("line", { x1: x, x2: x, y1: m.t, y2: m.t + f.ih, style: "stroke: var(--ink-2)", "stroke-width": 1, opacity: 0.6 }, svg);
        if (hv.chartId === c.id) {
          const counts = s.m.waiting.age_histogram?.counts || [];
          const rowsOut = counts.map((n, i) => ({ n, i })).filter((r) => r.n).reverse()
            .map((r) => ({ color: c.color, value: fmtInt(r.n), label: `waiting ${AGE_LABELS[r.i]}` }));
          if (!rowsOut.length) rowsOut.push({ color: null, value: "0", label: "waiting" });
          showTip(c, x, m.t, fmtAgo(x1 - s.t), rowsOut);
          tipShown = true;
        }
      }
    }
    if (!tipShown) c.tip.style.display = "none";
    mount(c, svg);
  }

  function mount(c, svg) {
    c.host.querySelector("svg")?.remove();
    c.host.insertBefore(svg, c.tip);
  }

  function showTip(c, x, top, title, rows) {
    const tip = c.tip;
    tip.replaceChildren();
    const head = document.createElement("div");
    head.className = "t";
    head.textContent = title;
    tip.appendChild(head);
    for (const row of rows) {
      const r = document.createElement("div");
      r.className = "r";
      const key = document.createElement("i");
      key.style.background = row.color || "transparent";
      const b = document.createElement("b");
      b.textContent = row.value;
      const span = document.createElement("span");
      span.textContent = row.label;
      r.append(key, b, span);
      tip.appendChild(r);
    }
    tip.style.display = "block";
    const w = tip.offsetWidth;
    const left = x + 12 + w > c.host.clientWidth ? x - 12 - w : x + 12;
    tip.style.left = `${Math.max(0, left)}px`;
    tip.style.top = `${top + c.notes.offsetHeight}px`;
  }

  // ---------------------------------------------------------------- layout

  function legend(host, items) {
    host.replaceChildren();
    for (const it of items) {
      const span = document.createElement("span");
      const key = document.createElement("i");
      if (it.kind) key.className = it.kind;
      key.style.background = it.color;
      span.append(key, document.createTextNode(it.label));
      host.appendChild(span);
    }
  }

  function card(parent, title, chartId, legendItems) {
    const div = document.createElement("div");
    div.className = "card";
    const head = document.createElement("div");
    head.className = "card-head";
    const h2 = document.createElement("h2");
    h2.textContent = title;
    head.appendChild(h2);
    if (legendItems) {
      const lg = document.createElement("div");
      lg.className = "legend";
      legend(lg, legendItems);
      head.appendChild(lg);
    }
    const chart = document.createElement("div");
    chart.className = "chart";
    chart.id = chartId;
    div.append(head, chart);
    parent.appendChild(div);
  }

  // Headline numbers at the top of the page. `better` says which direction
  // favors central; "match" means both sides should report the same value.
  const SCORES = [
    { key: "waiting", label: "Requests waiting for a host", value: (s) => s.m.waiting.count, fmt: fmtInt, better: "lower", min: 5, primary: true },
    { key: "oldest", label: "Oldest wait", value: (s) => s.m.waiting.oldest_seconds, fmt: fmtDur, better: "lower", min: 2 },
    { key: "p95", label: "p95 wait for a host (last 60s)", value: (s) => s.m.latency.queue_to_allocated.p95_seconds, fmt: fmtDur, better: "lower", min: 2 },
    { key: "placed", label: "Placed on a host / min", value: (s) => s.rates.allocations, fmt: fmtRate, better: "higher", min: 5 },
    { key: "incoming", label: "Incoming / min", value: (s) => s.rates.arrivals, fmt: fmtRate, better: "match", min: 5 },
  ];

  function buildScoreboard() {
    const host = document.getElementById("scoreboard");
    for (const k of SCORES) {
      const tile = document.createElement("div");
      tile.className = `score${k.primary ? " primary" : ""}`;
      const label = document.createElement("div");
      label.className = "label";
      label.textContent = k.label;
      const pair = document.createElement("div");
      pair.className = "pair";
      for (const side of SIDES) {
        const cell = document.createElement("div");
        const who = document.createElement("span");
        who.className = "who";
        const key = document.createElement("i");
        key.style.background = SIDE_INFO[side].color;
        who.append(key, document.createTextNode(SIDE_INFO[side].name));
        const num = document.createElement("b");
        num.className = "num";
        num.id = `score-${k.key}-${side}`;
        num.textContent = "—";
        cell.append(who, num);
        pair.appendChild(cell);
      }
      const cmp = document.createElement("div");
      cmp.className = "cmp";
      cmp.id = `score-${k.key}-cmp`;
      tile.append(label, pair, cmp);
      host.appendChild(tile);
    }
  }

  // How central compares with current, in words, plus a good/bad class.
  function compare(k, cur, cen) {
    if (cur == null || cen == null) return ["", ""];
    if (Math.max(cur, cen) < k.min) return k.better === "match" ? ["No incoming requests", ""] : ["Both near zero", ""];
    const d = cur > 0 ? (cen - cur) / cur : Infinity;
    const pct = Number.isFinite(d) ? `${Math.round(Math.abs(d) * 100)}%` : "";
    if (k.better === "match") {
      return Math.abs(d) < 0.05 ? ["✓ Same feed to both", "better"] : [`● Feeds differ by ${pct || "100%"}`, "worse"];
    }
    if (Math.abs(d) < 0.05) return ["≈ Central same as current", ""];
    const higher = d > 0;
    const good = higher === (k.better === "higher");
    // Big increases read better as a multiple ("10.0× higher", not "899% higher").
    let amount = higher && d >= 1 ? `${(d + 1).toFixed(1)}× ` : `${pct} `;
    if (!Number.isFinite(d)) amount = ""; // current is 0, so no ratio
    // The verdict is spelled out, not left to the color: higher is good for
    // some metrics and bad for others.
    const tail = Number.isFinite(d) ? "" : " (current is 0)";
    return [`${higher ? "▲" : "▼"} Central ${amount}${higher ? "higher" : "lower"}${tail} · ${good ? "better" : "worse"}`, good ? "better" : "worse"];
  }

  function buildColumns() {
    const cols = document.getElementById("cols");
    for (const side of SIDES) {
      const info = SIDE_INFO[side];
      const col = document.createElement("div");
      col.className = "col";
      col.id = `col-${side}`;
      const head = document.createElement("div");
      head.className = "col-head";
      const bar = document.createElement("span");
      bar.className = "bar";
      bar.style.background = info.color;
      const titles = document.createElement("div");
      const h2 = document.createElement("h2");
      h2.textContent = info.name;
      const p = document.createElement("p");
      p.textContent = info.sub;
      const err = document.createElement("p");
      err.className = "col-err";
      err.id = `err-${side}`;
      err.setAttribute("role", "status");
      titles.append(h2, p, err);
      head.append(bar, titles);
      col.appendChild(head);

      card(col, "Wait time spread", `spread-${side}`, [
        { label: "p50–p95", color: info.color, kind: "wash" },
        { label: "Oldest", color: info.color, kind: "line" },
      ]);
      card(col, "Age of waiting requests", `heat-${side}`, [{ label: "fewer → more requests", color: `linear-gradient(90deg, transparent, ${info.color})`, kind: "ramp" }]);
      card(col, "Requests by stage", `stages-${side}`, STAGES.map((s) => ({ label: s.label, color: s.color })).reverse());
      card(col, "Time in stage (oldest) vs paging limits", `stage-age-${side}`, STAGES.map((s) => ({ label: s.label, color: s.color, kind: "line" })));
      cols.appendChild(col);

      addChart(`spread-${side}`, {
        group: "spread", scaleKind: "duration", height: 170, aria: `Wait time p50 to p95 band and oldest, ${info.name}`,
        series: [
          { side, label: "p50–p95", color: info.color, fmt: fmtDur, value: (s) => s.m.waiting.p95_seconds, lo: (s) => s.m.waiting.p50_seconds },
          { side, label: "Oldest", color: info.color, fmt: fmtDur, value: (s) => s.m.waiting.oldest_seconds },
        ],
      });
      addChart(`heat-${side}`, {
        group: "heat", kind: "heatmap", side, color: info.color, height: 170, aria: `Waiting requests by age over time, ${info.name}`, series: [],
      });
      addChart(`stages-${side}`, {
        group: "stages", kind: "stacked", height: 160, aria: `Requests by stage over time, ${info.name}`,
        series: STAGES.map((st) => ({ side, label: st.label, color: st.color, fmt: fmtInt, value: (s) => s.m.stages[st.key] ?? 0 })),
      });
      addChart(`stage-age-${side}`, {
        group: "stage-age", scaleKind: "duration", height: 170, aria: `Oldest time in each stage with paging thresholds, ${info.name}`,
        alertMetrics: STAGES.map((st) => `stage_oldest_seconds.${st.key}`),
        series: STAGES.map((st) => ({ side, label: st.label, color: st.color, fmt: fmtDur, value: (s) => metric(s, `stage_oldest_seconds.${st.key}`) })),
      });
    }

    const both = (value, fmt) => SIDES.map((side) => ({ side, label: SIDE_INFO[side].name, color: SIDE_INFO[side].color, fmt, value }));
    addChart("h2h-incoming", {
      group: "flow", height: 200, aria: "Incoming requests per minute, current vs central",
      series: both((s) => s.rates.arrivals, fmtRate),
    });
    addChart("h2h-placed", {
      group: "flow", height: 200, aria: "Requests placed on a host per minute, current vs central",
      series: both((s) => s.rates.allocations, fmtRate),
    });
    addChart("h2h-waiting", { height: 200, aria: "Requests waiting for a host, current vs central", series: both((s) => s.m.waiting.count, fmtInt) });
    addChart("h2h-wait", {
      height: 200, scaleKind: "duration", aria: "Wait time, current vs central",
      series: both((s) => metric(s, WAIT_STATS[state.waitStat].path), fmtDur),
    });
    addChart("h2h-util", {
      height: 200, scaleKind: "pct", aria: "Fleet utilization, current vs central", alertMetrics: ["fleet.utilization"],
      series: both((s) => metric(s, "fleet.utilization"), fmtPct),
    });
    addChart("h2h-checks", { height: 200, aria: "Scheduling checks per minute, current vs central", series: both((s) => s.rates.checks, fmtRate) });
    // One small head-to-head chart per runner size, all on one scale, so a
    // size that starves while others are placed stands out.
    const grid = document.getElementById("size-grid");
    for (const size of SIZES) {
      const cell = document.createElement("div");
      const h4 = document.createElement("h4");
      h4.textContent = `${size} vCPU`;
      const chart = document.createElement("div");
      chart.className = "chart";
      chart.id = `size-${size}`;
      cell.append(h4, chart);
      grid.appendChild(cell);
      const bySize = (s) => SIZE_STATS[state.sizeStat].value(s, size);
      addChart(`size-${size}`, {
        group: "by-size", compact: true, height: 140, margin: { l: 40, r: 44, t: 8, b: 22 },
        scaleKind: SIZE_STATS[state.sizeStat].kind, aria: `${size} vCPU runners, current vs central`,
        series: both(bySize, (v) => SIZE_STATS[state.sizeStat].fmt(v)),
      });
    }
    for (const lg of document.querySelectorAll('[data-legend="sides"]')) {
      legend(lg, SIDES.map((s) => ({ label: SIDE_INFO[s].name, color: SIDE_INFO[s].color, kind: "line" })));
    }
  }

  // ---------------------------------------------------------------- render

  function renderCharts() {
    const x1 = viewEnd();
    const x0 = x1 - state.windowMs;
    for (const list of Object.values(groups)) {
      const scale = groupScale(list, x0, x1);
      for (const c of list) (c.kind === "heatmap" ? renderHeatmap : renderLines)(c, scale, x0, x1);
    }
  }

  // Explain the selected by-size view, and say when a side doesn't report it.
  function renderSizeNote() {
    const stat = SIZE_STATS[state.sizeStat];
    const missing = stat.field
      ? SIDES.filter((side) => {
        const s = sampleAt(side);
        return s && metricAt(s.m, stat.field) == null;
      })
      : [];
    const gap = missing.length ? ` Not reported yet by ${missing.map((side) => SIDE_INFO[side].name).join(" or ")} (${stat.field}).` : "";
    document.getElementById("size-note").textContent = `Same scale for every size. ${stat.note}${gap}`;
  }
  const metricAt = (m, path) => path.split(".").reduce((v, k) => v?.[k], m);

  function renderScoreboard() {
    const samples = Object.fromEntries(SIDES.map((side) => [side, sampleAt(side)]));
    for (const k of SCORES) {
      const values = {};
      for (const side of SIDES) {
        values[side] = samples[side] ? k.value(samples[side]) : null;
        document.getElementById(`score-${k.key}-${side}`).textContent = values[side] == null ? "—" : k.fmt(values[side]);
      }
      const [text, cls] = compare(k, values.current, values.central);
      const cmp = document.getElementById(`score-${k.key}-cmp`);
      cmp.textContent = text;
      cmp.className = `cmp ${cls}`;
    }
  }

  function renderConnections() {
    const labels = { live: "● Live", stale: "◐ Stale", error: "✕ Error", connecting: "… Connecting" };
    for (const side of SIDES) {
      const pill = document.getElementById(`conn-${side}`);
      const st = sideStatus(side);
      pill.dataset.state = st;
      pill.replaceChildren();
      const key = document.createElement("i");
      key.className = "key";
      key.style.background = SIDE_INFO[side].color;
      const name = document.createElement("span");
      name.textContent = SIDE_INFO[side].name;
      const status = document.createElement("span");
      status.className = "state";
      status.textContent = labels[st];
      pill.append(key, name, status);
      const error = state.sides[side].error;
      pill.title = `${sourceOf(side)}${error ? ` — ${error}` : ""}`;
      document.getElementById(`col-${side}`).classList.toggle("stale", st !== "live" && !state.paused);
      document.getElementById(`err-${side}`).textContent = st === "live" || !error ? "" : `Can't load metrics from ${sourceOf(side)}: ${error}`;
    }
  }

  function renderTable() {
    const rows = [
      ...STAGES.map((st) => [st.label, (s) => fmtInt(s.m.stages[st.key])]),
      ["Running", (s) => fmtInt(s.m.stages.running)],
      ...STAGES.map((st) => [`Oldest in ${st.label.toLowerCase()}`, (s) => fmtDur(metric(s, `stage_oldest_seconds.${st.key}`))]),
      ["Wait p50 / p95 / oldest", (s) => `${fmtDur(s.m.waiting.p50_seconds)} / ${fmtDur(s.m.waiting.p95_seconds)} / ${fmtDur(s.m.waiting.oldest_seconds)}`],
      ["Wait for host p50 / p95 / p99 (60s)", (s) => {
        const q = s.m.latency.queue_to_allocated;
        return `${fmtDur(q.p50_seconds)} / ${fmtDur(q.p95_seconds)} / ${fmtDur(q.p99_seconds)}`;
      }],
      ["Arrivals / min", (s) => fmtRate(s.rates.arrivals)],
      ["Allocations / min", (s) => fmtRate(s.rates.allocations)],
      ["Scheduling checks / min", (s) => fmtRate(s.rates.checks)],
      ["Order inversions (total)", (s) => fmtInt(s.m.counters.order_inversions_total)],
      ["Fleet used", (s) => `${fmtPct(metric(s, "fleet.utilization"))} (${fmtInt(s.m.fleet.vcpus_used)} vCPU)`],
    ];
    const table = document.getElementById("snapshot");
    table.replaceChildren();
    const thead = table.createTHead().insertRow();
    for (const h of ["Metric", ...SIDES.map((s) => SIDE_INFO[s].name)]) {
      const th = document.createElement("th");
      th.textContent = h;
      thead.appendChild(th);
    }
    const body = table.createTBody();
    const samples = SIDES.map(sampleAt);
    for (const [label, f] of rows) {
      const tr = body.insertRow();
      tr.insertCell().textContent = label;
      for (const s of samples) tr.insertCell().textContent = s ? f(s) : "—";
    }
  }

  function render() {
    renderConnections();
    renderScoreboard();
    renderSizeNote();
    renderCharts();
    renderTable();
  }

  // ---------------------------------------------------------------- controls

  let toastTimer = 0;
  function toast(msg) {
    const t = document.getElementById("toast");
    t.textContent = msg;
    t.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove("show"), 3500);
  }

  // ---------------------------------------------------------------- traffic

  // The serving process relays these to the load generator (or drives its
  // simulation), see /control/* in mock_server.py.
  async function controlCall(method, path) {
    const r = await fetch(path, { method, cache: "no-store" });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    return body;
  }

  const traffic = { status: null, error: null, busy: false, rateDirty: false, confirmUntil: 0 };
  const CONFIRM_BURST_AT = 2000;

  function renderTraffic() {
    const st = traffic.status;
    const now = document.getElementById("rate-now");
    now.classList.toggle("err", !!traffic.error);
    now.title = traffic.error || "";
    now.textContent = traffic.error
      ? "▲ Load generator unreachable"
      : st ? `Now ${fmtInt(st.rate_per_min)} / min (${fmtRate(st.rate_per_min / 60)} / s)` : "…";
    if (st && !traffic.rateDirty && document.activeElement?.id !== "rate-input") setRateInputs(st.rate_per_min);
  }

  function setRateInputs(v) {
    document.getElementById("rate-input").value = Math.round(v);
    const slider = document.getElementById("rate-slider");
    // Widen the slider when the generator already runs above its range.
    if (v > Number(slider.max)) slider.max = Math.ceil((v * 1.5) / 600) * 600;
    slider.value = Math.round(v);
  }

  async function refreshTraffic() {
    try {
      traffic.status = await controlCall("GET", "/control/status");
      traffic.error = null;
    } catch (e) {
      traffic.error = e.message;
    }
    renderTraffic();
  }

  async function act(button, fn) {
    if (traffic.busy) return;
    traffic.busy = true;
    button.disabled = true;
    try {
      await fn();
    } catch (e) {
      toast(`Traffic control failed: ${e.message}`);
    } finally {
      traffic.busy = false;
      button.disabled = false;
      refreshTraffic();
    }
  }

  function bindTraffic() {
    const slider = document.getElementById("rate-slider");
    const input = document.getElementById("rate-input");
    slider.addEventListener("input", () => {
      input.value = slider.value;
      traffic.rateDirty = true;
    });
    input.addEventListener("input", () => {
      slider.value = Math.min(Number(slider.max), Number(input.value) || 0);
      traffic.rateDirty = true;
    });
    const setRate = document.getElementById("rate-set");
    setRate.addEventListener("click", () => act(setRate, async () => {
      const value = Math.max(0, Number(input.value) || 0);
      await controlCall("POST", `/control/rate?value=${value}`);
      traffic.rateDirty = false;
      toast(value ? `Steady rate set to ${fmtInt(value)} / min` : "Steady traffic stopped");
    }));

    const count = document.getElementById("burst-input");
    const send = document.getElementById("burst-send");
    const resetSend = () => {
      traffic.confirmUntil = 0;
      send.textContent = "Send burst";
    };
    count.addEventListener("input", resetSend);
    send.addEventListener("click", () => {
      const n = Math.round(Number(count.value) || 0);
      if (n < 1) return toast("Enter how many requests to send");
      // Large bursts take a second click, so a stray click can't flood both control planes.
      if (n >= CONFIRM_BURST_AT && Date.now() > traffic.confirmUntil) {
        traffic.confirmUntil = Date.now() + 4000;
        send.textContent = `Confirm ${fmtInt(n)}?`;
        setTimeout(() => Date.now() >= traffic.confirmUntil && resetSend(), 4100);
        return;
      }
      resetSend();
      act(send, async () => {
        await controlCall("POST", `/control/burst?count=${n}`);
        toast(`Sent a burst of ${fmtInt(n)} requests`);
      });
    });
  }

  function bindSeg(selector, attr, current, onPick) {
    const buttons = document.querySelectorAll(selector);
    for (const b of buttons) {
      b.setAttribute("aria-pressed", String(b.dataset[attr] === String(current)));
      b.addEventListener("click", () => {
        for (const o of buttons) o.setAttribute("aria-pressed", String(o === b));
        onPick(b.dataset[attr]);
      });
    }
  }

  function bindControls() {
    bindSeg("[data-window]", "window", state.windowMs, (v) => {
      state.windowMs = Number(v);
      writeStored({ windowMs: state.windowMs });
      render();
    });
    bindSeg("[data-stat]", "stat", state.waitStat, (v) => {
      state.waitStat = v;
      writeStored({ waitStat: v });
      renderCharts();
    });
    bindSeg("[data-sizestat]", "sizestat", state.sizeStat, (v) => {
      state.sizeStat = v;
      writeStored({ sizeStat: v });
      for (const c of groups["by-size"]) c.scaleKind = SIZE_STATS[v].kind;
      renderSizeNote();
      renderCharts();
    });

    const pause = document.getElementById("pause");
    pause.addEventListener("click", () => {
      state.paused = !state.paused;
      state.frozenEnd = state.paused ? latestT() : null;
      pause.textContent = state.paused ? "Resume" : "Pause";
      pause.setAttribute("aria-pressed", String(state.paused));
      render();
    });
    document.getElementById("clear").addEventListener("click", () => {
      for (const s of SIDES) state.sides[s].hist = [];
      state.markers = [];
      render();
    });

    const form = document.getElementById("settings");
    // The fields show the real endpoint. Entering the one this server proxies
    // keeps fetching through the server (HTTPS- and CORS-safe); any other URL
    // is fetched by the browser directly.
    const fill = (v) => {
      for (const k of Object.keys(DEFAULTS)) {
        form.elements[k].value = SIDES.includes(k) && v[k] === DEFAULTS[k] && upstreams[k] ? upstreams[k] : v[k];
      }
    };
    form.closest("details").addEventListener("toggle", (e) => e.target.open && fill(cfg));
    fill(cfg);
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      const next = {};
      for (const k of Object.keys(DEFAULTS)) next[k] = form.elements[k].value.trim();
      for (const side of SIDES) {
        if (!next[side] || next[side] === upstreams[side]) next[side] = DEFAULTS[side];
      }
      next.interval = Math.max(250, Number(next.interval) || DEFAULTS.interval);
      const endpointsChanged = next.current !== cfg.current || next.central !== cfg.central;
      Object.assign(cfg, next);
      writeStored(next);
      if (endpointsChanged) {
        for (const s of SIDES) Object.assign(state.sides[s], { hist: [], error: null, lastOk: 0 });
        state.markers = [];
      }
      form.closest("details").open = false;
      clearTimeout(pollTimer);
      poll();
    });
    document.getElementById("settings-reset").addEventListener("click", () => fill(DEFAULTS));

    let resizeRaf = 0;
    window.addEventListener("resize", () => {
      cancelAnimationFrame(resizeRaf);
      resizeRaf = requestAnimationFrame(renderCharts);
    });
  }

  buildScoreboard();
  buildColumns();
  bindControls();
  render();
  bindTraffic();
  loadServerConfig().then(loadHistory).then(() => {
    render();
    poll();
    refreshTraffic();
    setInterval(refreshTraffic, 3000);
  });
})();
