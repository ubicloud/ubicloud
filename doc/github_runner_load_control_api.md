# Load Generator Control API

A tiny HTTP API exposed by `bin/github_runner_load` **while a load run is in
progress**. It lets you change the request rate and inject bursts of immediate
load without restarting the run.

- **Base URL:** `http://144.76.169.97:9299` (default)
- **Dependencies:** none (built on Ruby's `TCPServer`)
- **Lifetime:** up only for the duration of a load run

## Enabling / configuring

The API is **on by default** whenever a real run starts (it is disabled
automatically with `--dry-run`).

| Flag | Default | Meaning |
|---|---|---|
| `--control-port N` | `9299` | TCP port to bind |
| `--control-host HOST` | `0.0.0.0` | Bind address (use `127.0.0.1` to keep it local) |
| `--no-control` | (enabled) | Disable the control API entirely |

Startup logs a line like:
```
[github_runner_load] control API on http://0.0.0.0:9299 (GET /status, POST /rate?value=N, POST /burst?count=N, POST /stop)
```

## Conventions

- All responses are `application/json`, sent with `Connection: close`.
- Parameters may be passed as **query string** or as a **JSON body**
  (`{"rate": 3600}`); body values override query values when both are present.
- Unknown paths return `404` with the list of valid endpoints.
- Errors return `400` (bad request) or `500` (unexpected).

---

## `GET /status`

Returns the current rate and per-target counters.

```bash
curl -s http://144.76.169.97:9299/status
```

```json
{
  "rate_per_min": 1800.0,
  "stopping": false,
  "targets": [
    {
      "name": "current",
      "url": "http://144.76.171.226:9292",
      "repository": "my-org/my-repo",
      "events": { "workflow_job": { "sent": 11609, "ok": 11609, "failed": 0 } },
      "registered": 5641,
      "label_counts": { "ubicloud-standard-2": 4600, "ubicloud-standard-4": 2900 }
    },
    {
      "name": "sorting-hat",
      "url": "http://46.4.181.62:3000",
      "repository": "other-org/other-repo",
      "events": { "workflow_job": { "sent": 6202, "ok": 6202, "failed": 0 } },
      "registered": 2954,
      "label_counts": { "ubicloud-standard-2": 2400 }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `rate_per_min` | Current configured rate (jobs per minute, per target) |
| `stopping` | `true` after `/stop` has been called |
| `targets[].events.workflow_job` | Webhook counters: `sent`, `ok` (2xx), `failed` |
| `targets[].registered` | Runner ids observed registered via the fake API |
| `targets[].label_counts` | Queued jobs per label |

> `sent` counts **all** webhook events (queued + in_progress + completed), so it
> is larger than the queued rate. The queued rate is `rate_per_min`.

---

## `POST /rate`

Set the rate, in **jobs per minute**, applied to **every** target. Takes effect
on the next scheduled arrival (does not disturb in-flight requests).

Parameter: `value` (or `rate`) — required, a number (fractions allowed).

```bash
curl -s -X POST 'http://144.76.169.97:9299/rate?value=3600'
# or JSON body:
curl -s -X POST http://144.76.169.97:9299/rate -H 'content-type: application/json' -d '{"rate": 3600}'
```

```json
{ "rate_per_min": 3600.0 }
```

Errors:
```json
{ "error": "missing rate" }      // 400 when no value/rate given
```

Examples:

| Goal | Call |
|---|---|
| ~30/s per target | `POST /rate?value=1800` |
| ~60/s per target | `POST /rate?value=3600` |
| Back off to ~5/s | `POST /rate?value=300` |
| Pause-paced load (0) | `POST /rate?value=0` (bursts still work) |

---

## `POST /burst`

Enqueue **N jobs immediately** to **each** target, bypassing the paced producer.
The call returns instantly; the jobs are pushed onto the worker queues by a
background thread, so it is safe to call even when the queues are busy.

Parameter: `count` — optional, default `100`, must be `> 0`.

```bash
curl -s -X POST 'http://144.76.169.97:9299/burst?count=1000'
# or JSON body:
curl -s -X POST http://144.76.169.97:9299/burst -H 'content-type: application/json' -d '{"count": 500}'
```

```json
{ "burst": 1000 }
```

Errors:
```json
{ "error": "count must be > 0" }   // 400 when count <= 0
```

> Burst jobs use the same label distribution and payload path as normal load.
> `count` is applied to every target (N each), not split.

---

## `POST /stop`

Stop the run. The paced producer and the finisher loop exit, and the final
per-target report is printed.

This is the **normal way to end a run**, since the default duration is
**infinite** (the load generator runs until told to stop).

```bash
curl -s -X POST http://144.76.169.97:9299/stop
```

```json
{ "stopping": true }
```

---

## Worked example

```bash
# 1. start a run at 1800/min per target
~/.local/bin/mise exec -- ruby github_runner_load --config targets.yml --rate 1800

# 2. (another shell) watch the counters
curl -s http://144.76.169.97:9299/status

# 3. ramp up
curl -s -X POST 'http://144.76.169.97:9299/rate?value=3600'

# 4. slam both environments with 1000 extra jobs each
curl -s -X POST 'http://144.76.169.97:9299/burst?count=1000'

# 5. confirm the spike landed
curl -s http://144.76.169.97:9299/status

# 6. end early
curl -s -X POST http://144.76.169.97:9299/stop
```

## Notes and caveats

- **In-memory and process-scoped.** The rate and counters live only in the
  running process; restarting the load generator resets them.
- **Rate is per target.** `value` is applied identically to every target, so a
  combined rate of `R` across `N` targets means `value = R / N`.
- **Poisson arrivals.** The paced producer uses exponential inter-arrival times,
  so the per-second count varies around the mean even with a fixed rate.
- **Security.** Binds `0.0.0.0` by default. On a shared host, prefer
  `--control-host 127.0.0.1` (and reach it via SSH tunnel) or firewall port 9299.
