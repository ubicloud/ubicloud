# Runner scheduler dashboard

A live, side-by-side comparison of two control planes scheduling GitHub
runners:

- **Current:** today's code path. Each runner is its own strand: over-quota
  runners poll `wait_concurrency_limit` every 5–15s, and VMs retry the
  allocator on a 5–30s backoff after `NoSpaceLeft`.
- **Central:** the proposed centralized scheduler, with one queue dispatched
  whenever capacity changes.

Both receive the same stream of fake GitHub jobs. The dashboard polls each
control plane's metrics endpoint every second.

| File | What it is |
|---|---|
| `index.html`, `dashboard.js` | The dashboard. Static, no build step, no external dependencies (works offline). |
| [`METRICS.md`](METRICS.md) | **Spec for the metrics endpoint** each control plane must expose. Hand this to whoever implements them. |
| `mock_server.py` | Simulates both control planes and serves their metrics, so the dashboard works before the real endpoints exist. |
| `inject.py` | CLI that sends fake job bursts and load changes to the mock. |

## Run it

```bash
python3 demo/scheduler-dashboard/mock_server.py
```

Open http://localhost:8787/, then inject a burst:

```bash
python3 demo/scheduler-dashboard/inject.py --count 300
```

- **Only standard-library Python 3 is needed.** If mise refuses because
  `mise.toml` isn't trusted, either run `mise trust` or call a Python outside
  the repo's mise shims.
- **Keep the tab open.** The dashboard holds its history in memory, so
  reloading the page clears the charts.

### Adjusting the fake data

These are `mock_server.py` flags:

| Flag | Default | Effect |
|---|---|---|
| `--hosts`, `--host-vcpus` | 24 × 64 | Fleet size (1,536 vCPU) |
| `--rate` | 46 / min | Background requests, about 65% fleet utilization |
| `--demo-quota` | 600 vCPU | Quota of the project that receives injected bursts. The current scheduler's admission gate only applies above quota. |
| `--speed` | 1 | Simulated seconds per real second. Use 4–8 to rehearse a full drain quickly. The time axis stays wall-clock; wait and drain times use simulated time. |
| `--warmup` | 600 s | Simulated time before serving, so the fleet starts at steady state |
| `--seed` | 7 | Random seed |

Runner size mix, boot and run durations, and the central scheduler's
reservation threshold are constants at the top of `mock_server.py`.

At runtime, `inject.py` options adjust the load:

- `--count N`: number of requests in the burst.
- `--vcpus 30`: only one runner size.
- `--spread S`: seconds over which the burst arrives.
- `--rate R`: set the background rate, in requests per minute.

## Point it at real control planes

**Recommended:** have the server proxy the real endpoints, so the dashboard
keeps fetching from its own origin:

```bash
python3 demo/scheduler-dashboard/mock_server.py \
  --current-url http://144.76.171.226:9292/scheduler/metrics \
  --central-url http://46.4.181.62:3000/scheduler/metrics
```

- **Why proxy:** this avoids CORS, and avoids the browser blocking plain-HTTP
  endpoints when the page is served over HTTPS (e.g. through a Cloudflare
  tunnel).
- **Settings panel:** the Endpoints panel keeps the default paths
  (`/current/scheduler/metrics`, `/central/scheduler/metrics`) and shows
  which real endpoint the server fetches for each.
- **Unreachable endpoints:** if one can't be reached, its column says so
  with the error, e.g. connection refused.
- **Mixing real and simulated:** leave out either flag to keep that side
  simulated. Then match `--hosts` and `--host-vcpus` to the real fleet, and
  pass `--rate 0` so the simulated side only gets the bursts you inject.

**Alternatively, fetch directly from the browser.** Use the **Endpoints** menu
in the top bar, or URL parameters:

```
http://localhost:8787/?current=http://cp-current:3000/scheduler/metrics&central=http://cp-central:3000/scheduler/metrics&interval=1000
```

Settings are remembered in the browser. This only works when the endpoints
send CORS headers and use the same scheme (HTTP or HTTPS) as the page.

## Traffic controls

The **Traffic** panel sets the load generator's steady rate (slider or number,
then **Set rate**) and sends bursts (**Send burst**; bursts of 2,000
or more take a second click to confirm). Next to the rate it shows the
generator's current rate, or a warning when it can't be reached.

Start the server with the load generator's address:

```bash
python3 demo/scheduler-dashboard/mock_server.py ... --control-url http://144.76.169.97:9299
```

The server relays only `GET /status`, `POST /rate?value=` and
`POST /burst?count=`, and checks the numbers first: rate 0–100,000 per minute,
burst 1–20,000. The generator sends no CORS headers and speaks plain HTTP, so
the browser can't call it directly. Without `--control-url`, the panel drives
the server's own simulation instead.

⚠️ Anyone who can open the dashboard, including through a public tunnel, can
use these controls.

## What the dashboard shows

From top to bottom:

1. **Scoreboard.** Current and central side by side, with how central
   compares:
   - Requests waiting for a host (the large tile).
   - Oldest wait.
   - p95 wait for a host.
   - Placed per minute.
   - Incoming per minute. This tile instead checks that both sides get the
     same feed.
2. **Traffic.** The load-generator controls above.
3. **Head to head.** Both control planes on each chart:
   - Incoming requests and requests placed on a host, per minute.
   - Requests waiting for a host.
   - Wait time, switchable between p50, p95 and oldest.
   - Fleet utilization, with the 80% admission gate as an amber line.
   - Scheduling checks per minute: control-plane work spent on scheduling.
4. **By runner size.** One small chart per size (2–30 vCPU) on a shared scale,
   switchable between:
   - Oldest wait, waiting count, and waiting vCPU.
   - Placed / min and free slots. These two need the optional
     `*_by_vcpus` fields in METRICS.md.

   Large runners starving shows as the 16 and 30 vCPU charts climbing while
   the small ones stay flat. Fragmentation shows as free slots for 30 vCPU
   reaching zero while small slots remain.
5. **Inside each scheduler.** One column per control plane; side-by-side
   charts share a scale.
   - Wait time spread: a p50–p95 band with the oldest request as a line.
   - Age of waiting requests: a heatmap of how long waiting requests have
     waited. A request served in order (FIFO) leaves a clean diagonal; a
     long smear means requests are left behind.
   - Requests by stage: admission, capacity, booting and idle, stacked.
   - Time in stage vs paging limits: the oldest request in each stage. Red
     lines are paging thresholds and amber lines are monitoring thresholds,
     both taken from each control plane's `alerts`. A threshold far above
     the data is listed above the chart until the data gets within 25% of
     it.
6. **Snapshot table.** Collapsed at the bottom: the latest values as a
   table.

Every time chart has a crosshair that's synced across all charts. When one
poll sees 25 or more new requests, the dashboard marks a burst on every time
chart. The server records both sides every second, so reloading the page or
opening it late starts with the last 15 minutes.

## What the mock models, and what it doesn't

It follows `Prog::Github::GithubRunnerNexus` and `Prog::Vm::Metal::Nexus#start`:

- **Quota check:** quota is checked with 0 extra usage against stale reads,
  so a burst can overshoot.
- **Over-quota runners:** they pass the gate anyway once utilization is ≤ 80%.
- **Allocator retries:** back off `clamp(30 / (1 + waited / 120), 5, 30)`
  seconds after `NoSpaceLeft`.

Both control planes use identical random host placement, so differences come
only from queueing and admission.

It does **not** model:

- VM pools.
- AWS spill-over.
- Custom-label limits.
- Respirate scheduling latency.

Treat its numbers as illustrative. The real comparison comes from the real
endpoints.
