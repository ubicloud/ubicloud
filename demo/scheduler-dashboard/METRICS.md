# Scheduler metrics endpoint: spec (v2)

Both control planes (the **current** one running today's per-runner polling and
the **central** one running the new scheduler) expose the same endpoint. The
dashboard polls each one about once a second and draws them side by side, so
the two payloads must mean exactly the same thing.

- [What's new in v2](#whats-new-in-v2)
- [Endpoint](#endpoint)
- [Payload](#payload)
- [What to build first](#what-to-build-first)
- [Field definitions](#field-definitions)
- [Alerts: paging and monitoring thresholds](#alerts-paging-and-monitoring-thresholds)
- [Implementing it on the current control plane](#implementing-it-on-the-current-control-plane)
- [Implementing it on the central scheduler](#implementing-it-on-the-central-scheduler)
- [Load controls (proposed, for the dashboard buttons)](#load-controls-proposed-for-the-dashboard-buttons)
- [Checking your implementation](#checking-your-implementation)

## What's new in v2

| Change | Why |
|---|---|
| `schema_version` is `2` | |
| New stage `stages.idle`; `booting` now ends when the runner is ready | Separates boot time (which can page) from waiting for GitHub to hand over the job |
| New `stage_oldest_seconds` | How long the oldest request has been in each stage. Today's paging rules are defined on these. |
| New `waiting.age_histogram` | Drives the "age of waiting requests" heatmap |
| New `alerts` | Each control plane declares its paging and monitoring thresholds; the dashboard draws them as red and amber lines |

The dashboard still renders a v1 payload, but the charts that depend on the new
fields stay empty.

## Endpoint

```
GET /scheduler/metrics
```

- **Response:** `200` with `Content-Type: application/json`. The path is
  configurable in the dashboard, so any path works.
- **CORS:** send `Access-Control-Allow-Origin: *`. The dashboard is a
  standalone page on a different origin.
- **No caching:** send `Cache-Control: no-store`.
- **Fast and cheap:** it's polled every second, so aim for under 100 ms. It
  must never block the scheduler.
- **Auth:** none for the demo. Bind to localhost or a dev network only.
- **Snapshot semantics:** every field describes "now", except `counters`,
  which are monotonic totals. The dashboard derives rates by differencing
  counters between polls, so **don't** return rates.

## Payload

```json
{
  "schema_version": 2,
  "scheduler": "current",
  "display_name": "Current · per-runner polling",
  "generated_at": "2026-10-14T18:03:21.250Z",

  "stages": {
    "waiting_admission": 91,
    "waiting_capacity": 13,
    "booting": 22,
    "idle": 2,
    "running": 213
  },

  "stage_oldest_seconds": {
    "waiting_admission": 238.4,
    "waiting_capacity": 237.9,
    "booting": 23.1,
    "idle": 5.0
  },

  "waiting": {
    "count": 104,
    "oldest_seconds": 238.4,
    "p50_seconds": 201.0,
    "p95_seconds": 236.2,
    "age_histogram": {
      "le":     [10, 30, 60, 120, 300, 600, 1800, 3600, null],
      "counts": [ 0,  1,  1,   4,  98,   0,    0,    0,    0]
    }
  },

  "by_vcpus": [
    { "vcpus": 2,  "waiting": 36, "oldest_seconds": 238.4 },
    { "vcpus": 4,  "waiting": 25, "oldest_seconds": 238.1 },
    { "vcpus": 8,  "waiting": 21, "oldest_seconds": 237.0 },
    { "vcpus": 16, "waiting": 13, "oldest_seconds": 238.4 },
    { "vcpus": 30, "waiting": 9,  "oldest_seconds": 238.2 }
  ],

  "latency": {
    "window_seconds": 60,
    "queue_to_allocated": { "count": 141, "p50_seconds": 0.2, "p95_seconds": 81.0, "p99_seconds": 88.4 }
  },

  "counters": {
    "requests_received_total": 18234,
    "allocated_total": 18023,
    "started_total": 18001,
    "completed_total": 17805,
    "scheduling_checks_total": 92311,
    "order_inversions_total": 566
  },

  "fleet": { "vcpus_total": 1536, "vcpus_used": 1351 },

  "alerts": [
    { "id": "no_capacity_page", "label": "NoCapacity page", "metric": "stage_oldest_seconds.waiting_capacity",
      "threshold": 3600, "severity": "page", "source": "prog/vm/metal/nexus.rb#start" }
  ]
}
```

## What to build first

The dashboard degrades gracefully, so the fields can land in this order:

1. **Head-to-head view and burst race.** Nothing on the page renders without
   these.
   - `generated_at`
   - `stages`
   - `waiting.count`, `oldest_seconds`, `p50_seconds`, `p95_seconds`
   - `fleet`
   - `counters.requests_received_total`, `counters.scheduling_checks_total`
2. **Per-scheduler charts and paging lines.**
   - `stage_oldest_seconds`
   - `alerts`
   - `waiting.age_histogram`
   - `by_vcpus`
   - `latency`
3. **Everything else:** the rest of `counters` (shown in the snapshot table).

The dashboard requires `stages`, `waiting`, `counters`, `latency`, `fleet` and
`by_vcpus` to be **present**, even if some values inside are still `0`.

## Field definitions

### Terms

- **Request:** one runner request for one GitHub job, i.e. one `queued` webhook
  from the fake GitHub endpoint. On the current control plane, it's one
  `GithubRunner` row.
- **Arrived:** when the control plane received the request. On the current
  control plane, this is `github_runner.created_at`.
- **Allocated:** when the request's VM was **placed on a host**, so capacity is
  actually reserved. On the current control plane, this is `vm.allocated_at`.
  - ⚠️ Don't use `github_runner.allocated_at` for this. It's set in
    `allocate_vm` when the VM row is *created*, before the allocator has found
    a host.
- **Ready:** the runner is registered with GitHub and can take a job. On the
  current control plane, this is `github_runner.ready_at`.
- **Waiting:** arrived but not yet allocated.

### `stages`: current count of requests in each stage

Every live request is in exactly one stage. Stages run in this order.

| Key | Meaning | Current mapping | Central mapping |
|---|---|---|---|
| `waiting_admission` | Waiting, held back by policy (quota, utilization gate, custom-label concurrency) | strand label `start`, `wait_concurrency_limit`, `apply_custom_label_quota` | queued and not yet eligible under quota or policy |
| `waiting_capacity` | Waiting, allowed to run but no host fits yet | strand label `allocate_vm`, or `wait_vm` with `vm.allocated_at IS NULL` | queued, eligible, no host fits |
| `booting` | Allocated, runner not ready yet (VM boot, setup, registration) | `vm.allocated_at` set, `github_runner.ready_at IS NULL` | same |
| `idle` | Ready, waiting for GitHub to hand over the job | `ready_at` set, job not `in_progress` | same |
| `running` | Job is running | `workflow_job->>'status' = 'in_progress'` | same |

### `stage_oldest_seconds`: how long the oldest request has been in each stage

For each of `waiting_admission`, `waiting_capacity`, `booting` and `idle`: the
largest `now - entered_stage` over requests currently in that stage; `0` if
none.

| Stage | Entered the stage at (current control plane) |
|---|---|
| `waiting_admission` | `github_runner.created_at` |
| `waiting_capacity` | `vm.created_at`, which is exactly what the NoCapacity page measures. Use `github_runner.created_at` if no VM exists yet. |
| `booting` | `vm.allocated_at` |
| `idle` | `github_runner.ready_at` |

- **Requests that move back.** If a request can move back to an earlier stage
  (e.g. central re-classifying capacity → admission), "entered" means the
  **first** time it entered that stage. Ages must never reset just because a
  request bounced between stages.
- **No `running` key.** Running time isn't a scheduling concern.

### `waiting`: requests in the two waiting stages combined

| Field | Meaning |
|---|---|
| `count` | Number of waiting requests (`waiting_admission + waiting_capacity`) |
| `oldest_seconds` | `now - arrived` of the oldest waiting request; `0` if none |
| `p50_seconds`, `p95_seconds` | Percentiles of `now - arrived` over waiting requests; `0` if none |
| `age_histogram` | Waiting requests counted into fixed `now - arrived` buckets (see below) |

`age_histogram` details:

- `le` lists each bucket's upper bound in seconds. Use exactly
  `[10, 30, 60, 120, 300, 600, 1800, 3600, null]`; `null` means "over 1 hour".
- `counts[i]` is the number of waiting requests whose age falls in bucket `i`.
  Each request lands in the first bucket whose bound is `≥` its age.
- The counts sum to `count`.

### `by_vcpus`: waiting requests by runner size

Always include all five sizes (2, 4, 8, 16, 30), in that order, even when
zero. Size comes from `Github.runner_labels[label]["vcpus"]`. This is what
shows whether large runners are starving.

### `latency.queue_to_allocated`: allocation wait for recent requests

Covers requests **allocated within the last `window_seconds`** (use 60).

- `count` is how many requests that covers.
- The percentiles are of `allocated - arrived`, in seconds; all `0` if there
  are none.

This is the request-wait figure customers feel. Unlike `waiting.*`, it includes
requests that already got through.

### `counters`: monotonic totals since the process started

All counters may reset to zero on restart; the dashboard detects resets.

| Counter | Increment when |
|---|---|
| `requests_received_total` | A request arrives |
| `allocated_total` | A request is allocated (placed on a host) |
| `started_total` | Its job starts (webhook `in_progress`) |
| `completed_total` | Its job completes (webhook `completed`) |
| `scheduling_checks_total` | **Any attempt to admit or place a request**, successful or not. This measures how much work the control plane spends on scheduling. Current control plane: each run of `wait_concurrency_limit`, plus each `Scheduling::Allocator.allocate` call for a runner VM, including ones that raise `NoSpaceLeft`. Central: each placement attempt. |
| `order_inversions_total` | At allocation time, some **older** request **of the same or smaller size** is still waiting. Count at most once per allocation. This measures fairness: that older request could have used the capacity. |

### `fleet`: runner-fleet capacity

Measured in vCPU, over the hosts this control plane schedules runners onto.

| Field | Meaning |
|---|---|
| `vcpus_total` | Total vCPUs of `accepting` hosts |
| `vcpus_used` | Allocated vCPUs on those hosts |

Both control planes must use the same unit and the same host set, or the
utilization comparison is meaningless. The dashboard plots
`vcpus_used / vcpus_total` as `fleet.utilization`.

## Alerts: paging and monitoring thresholds

`alerts` lists the thresholds this control plane pages or acts on. The
dashboard draws each one as a horizontal line on every chart that plots its
`metric`:

- `page` severity is a **red** line.
- `monitor` severity is an **amber** line.
- A threshold far above the data shows as a note in the chart corner, and
  becomes a line once the data reaches 25% of it.

Each control plane declares its own rules, so the new scheduler can bring
different ones.

| Field | Meaning |
|---|---|
| `id` | Stable identifier |
| `label` | Short name shown on the line |
| `metric` | Dotted path into this payload. The dashboard currently draws lines for `stage_oldest_seconds.waiting_admission`, `stage_oldest_seconds.waiting_capacity`, `stage_oldest_seconds.booting`, `stage_oldest_seconds.idle`, and `fleet.utilization`. |
| `threshold` | Value in the metric's unit: seconds, or a 0–1 fraction for utilization |
| `severity` | `page` (someone gets paged) or `monitor` (logged or acted on automatically, no page) |
| `source` | Where in the code the rule lives, for reviewers |

### What the current control plane should declare

These come from today's code. Copy them as they are:

```json
[
  { "id": "no_capacity_page", "label": "NoCapacity page",
    "metric": "stage_oldest_seconds.waiting_capacity", "threshold": 3600, "severity": "page",
    "source": "prog/vm/metal/nexus.rb#start" },
  { "id": "boot_deadline_page", "label": "Boot deadline page",
    "metric": "stage_oldest_seconds.booting", "threshold": 600, "severity": "page",
    "source": "register_deadline(\"wait\", 10 * 60)" },
  { "id": "admission_gate", "label": "Admission gate",
    "metric": "fleet.utilization", "threshold": 0.8, "severity": "monitor",
    "source": "GithubRunnerNexus#wait_concurrency_limit" },
  { "id": "idle_recycle", "label": "Idle runner recycled",
    "metric": "stage_oldest_seconds.idle", "threshold": 310, "severity": "monitor",
    "source": "GithubRunnerNexus#wait" }
]
```

Where each rule comes from:

| Rule | Code | Behavior |
|---|---|---|
| **NoCapacity page** (severity `error`) | `Prog::Vm::Metal::Nexus#start` on `NoSpaceLeft` | Pages once a runner VM in the runner location has waited **60 min** since `vm.created_at` (**6 h** for 60-vCPU VMs, which the dashboard's sizes don't include). The page auto-resolves once it's over 15 min old and at most 1 VM is still queued. |
| **Boot deadline page** (severity `error`) | `register_deadline("wait", 10 * 60)` | Two consecutive 10-min deadlines: in `Vm::Metal::Nexus` after allocation (VM must boot), and in `GithubRunnerNexus#wait_vm` once the VM is up (runner must finish setup). The 600 s line approximates both. |
| **Admission gate** (monitoring) | `wait_concurrency_limit` | Over-quota runners wait while fleet utilization is above **80%**. |
| **Idle recycle** (monitoring) | `GithubRunnerNexus#wait` | A runner that hasn't picked up a job **5 min + 10 s** after `ready_at` is destroyed. |

Nothing pages on **`waiting_admission`**. A runner can sit in
`wait_concurrency_limit` indefinitely without anyone being paged. Only log
lines are emitted (`reached_concurrency_limit`, and `lack_of_capacity` from
the allocator). That gap is worth calling out in the demo.

## Implementing it on the current control plane

Most of the payload is a snapshot query over existing tables. The counters
need new instrumentation, because runner rows are deleted when they finish.

### Snapshot query

`stages`, `stage_oldest_seconds`, `waiting` (including the histogram) and
`by_vcpus` can all be computed from one query:

```sql
SELECT gr.label,
       gr.created_at,
       CASE
         WHEN s.label IN ('start','wait_concurrency_limit','apply_custom_label_quota') THEN 'waiting_admission'
         WHEN s.label = 'allocate_vm' OR v.allocated_at IS NULL                       THEN 'waiting_capacity'
         WHEN gr.ready_at IS NULL                                                     THEN 'booting'
         WHEN gr.workflow_job->>'status' = 'in_progress'                              THEN 'running'
         ELSE 'idle'
       END AS stage,
       CASE
         WHEN s.label IN ('start','wait_concurrency_limit','apply_custom_label_quota') THEN gr.created_at
         WHEN s.label = 'allocate_vm' OR v.allocated_at IS NULL                       THEN coalesce(v.created_at, gr.created_at)
         WHEN gr.ready_at IS NULL                                                     THEN v.allocated_at
         ELSE gr.ready_at
       END AS entered_stage_at
FROM github_runner gr
JOIN strand s ON s.id = gr.id
LEFT JOIN vm v ON v.id = gr.vm_id
WHERE s.label NOT IN ('destroy', 'wait_vm_destroy');
```

Group the result in Ruby:

- Map `gr.label` to vCPUs with `Github.runner_labels[label]["vcpus"]`.
- Age is `now - created_at` for `waiting.*`, and `now - entered_stage_at` for
  `stage_oldest_seconds`.

### Allocation latency

```sql
SELECT extract(epoch FROM v.allocated_at - gr.created_at) AS wait
FROM github_runner gr JOIN vm v ON v.id = gr.vm_id
WHERE v.allocated_at > now() - interval '60 seconds';
```

Runners that picked up a pool VM have no allocator wait. That's correct: they
count as near-instant allocations.

### Counters

They have to survive across respirate processes, so a per-process counter
won't work. Suggested: a one-row-per-counter table, with
`UPDATE scheduler_metric_counter SET value = value + 1 WHERE name = ?` at each
increment point. Pushing to VictoriaMetrics also works.

| Counter | Increment point |
|---|---|
| `requests_received_total` | `Prog::Github::GithubRunnerNexus.assemble` |
| `allocated_total` | `Prog::Vm::Metal::Nexus#start` after `Scheduling::Allocator.allocate` succeeds for a runner VM (`location_id == Location::GITHUB_RUNNERS_ID`), and in `pick_vm` when a pool VM is picked |
| `started_total`, `completed_total` | `helpers/webhook_github.rb` on `in_progress` / `completed` |
| `scheduling_checks_total` | Top of `wait_concurrency_limit`, and around `Scheduling::Allocator.allocate` in `Prog::Vm::Metal::Nexus#start` for runner VMs |
| `order_inversions_total` | At the same point as `allocated_total`: increment if an older waiting runner (stage `waiting_*`, `created_at` earlier) of the same or smaller size exists |

### Fleet

Fleet capacity uses the same host set as `wait_concurrency_limit`
(`VmHost.where(allocation_state: "accepting", location_id: Location::GITHUB_RUNNERS_ID)`):

- `vcpus_total = sum(total_cpus)`
- `vcpus_used = sum(used_cores * total_cpus / total_cores)`

### Alerts

Return the four entries in
[What the current control plane should declare](#what-the-current-control-plane-should-declare)
as a constant.

## Implementing it on the central scheduler

The central scheduler owns an explicit queue, so everything here should come
straight from its in-memory or queue state, without extra queries. Keep the
definitions identical to the ones above. In particular:

- **Stage definitions:**
  - `waiting_admission`: blocked by quota or policy.
  - `waiting_capacity`: eligible, but no host fits.
  - `booting`, `idle` and `running` are the same as on the current control
    plane.
- **Allocated** means host capacity is reserved for the request, exactly as on
  the current control plane.
- **`stage_oldest_seconds`:** use first entry into the stage (see above). A
  request that flips between admission and capacity as utilization moves must
  keep aging.
- **`scheduling_checks_total`:** count every placement attempt, including ones
  that fail. If the scheduler re-scans the queue on every capacity change,
  those attempts count.
- **`order_inversions_total`:** use the same definition as the current
  control plane. Deliberate backfill (a small request jumping a large one that
  doesn't fit yet) **does** count. That's fine and expected; the comparison
  shows how much of it there is.
- **`alerts`:** declare whatever the new scheduler will page on. Until that's
  decided, reuse the current control plane's list, so both sides are judged
  against the same lines.

## Load controls (proposed, for the dashboard buttons)

The dashboard's **Burst** and **Load −/+** buttons are wired but do nothing
yet. When the fake GitHub endpoint is ready, exposing these two calls lets
them be hooked up by setting one URL. The mock server already implements them.

```
POST /inject   {"count": 300, "vcpus": null, "spread": 5}
               → enqueue `count` fake `queued` jobs to BOTH control planes,
                 arriving evenly over `spread` seconds;
                 `vcpus` null = mixed sizes, or one of 2/4/8/16/30

POST /load     {"rate_per_min": 46}   or   {"delta_per_min": 10}
               → set (or step) the steady background arrival rate to both
                 control planes; respond with {"rate_per_min": <new rate>}
```

The burst must reach both control planes as the **same** job list (sizes and
durations), or the comparison isn't fair.

## Checking your implementation

The mock server serves a live, valid v2 payload you can diff against:

```bash
python3 demo/scheduler-dashboard/mock_server.py
curl -s localhost:8787/current/scheduler/metrics | jq
```

Then point the dashboard at your endpoint. Open **Endpoints** in the top bar,
or pass URL parameters:

```
http://localhost:8787/?current=http://localhost:3000/scheduler/metrics&central=http://localhost:4000/scheduler/metrics
```
