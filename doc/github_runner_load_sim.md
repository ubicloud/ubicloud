# GitHub Actions Runner Load Simulator

Tools for load-testing the Ubicloud GitHub Actions runner control plane without
touching real GitHub or real VMs. A **load generator** floods staging instances
with signed `workflow_job` webhooks, and a **fake GitHub API** absorbs the
control plane's outbound GitHub calls so it can drive the full
create → register → deregister lifecycle.

## Topology

```
                       ┌─────────────────────────────────────────┐
                       │  Load-sim VM  (ubi@144.76.169.97)        │
                       │                                          │
                       │  github_runner_load  ── control API :9299│
                       │        │                                 │
                       │        │ signed workflow_job webhooks     │
                       │        ▼                                 │
   ┌───────────────────┼──────────────────────────────────────────┼────────────┐
   │ staging "current" │        staging "sorting-hat"             │            │
   │ 144.76.171.226:9292        46.4.181.62:3000                 │            │
   │        │                          │                         │            │
   │        │ Octokit (OCTOKIT_API_ENDPOINT)                     │            │
   │        ▼                          ▼                         │            │
   │   fake-github-api :4567      fake-github-api :4568  ◄────────┼─ poll      │
   │   (namespace=staging)        (namespace=env2)       /_runners│  runner ids│
   └──────────────────────────────────────────────────────────────┴────────────┘
```

- The load generator **sends webhooks to staging** and **polls the fake API**
  to learn the `runner_id`s staging registered (so it can emit
  `in_progress`/`completed`).
- Each staging app is pointed at the fake API via
  `OCTOKIT_API_ENDPOINT`, one **port per environment** (namespaces keep their
  runner state isolated even when repo names are reused).

## Components and addresses

| Component | Address | Purpose |
|---|---|---|
| Load generator | load-sim VM `144.76.169.97` (`~/load-sim/github_runner_load`) | Sends webhooks; hosts the control API |
| Control API | `http://144.76.169.97:9299` (default) | Change rate / inject bursts while running |
| Fake GitHub API | `http://144.76.169.97:4567` (namespace `staging`) | Serves staging "current" |
| Fake GitHub API | `http://144.76.169.97:4568` (namespace `env2`) | Serves staging "sorting-hat" |

| Staging env | Webhook URL | `OCTOKIT_API_ENDPOINT` | installation_id | repository |
|---|---|---|---|---|
| current | `http://144.76.171.226:9292` | `http://144.76.169.97:4567` | `1` | `my-org/my-repo` |
| sorting-hat | `http://46.4.181.62:3000` | `http://144.76.169.97:4568` | `2` | `other-org/other-repo` |

> These instances do **not** verify the webhook signature, so the secret can be
> any value (`unused`).

---

## 1. Staging webhook endpoint (the load target)

### `POST /webhook/github`

Standard GitHub webhook endpoint. Accepts a `workflow_job` payload.

Headers:
- `content-type: application/json`
- `x-github-event: workflow_job`
- `x-hub-signature-256: sha256=<hmac>` — only required if the instance verifies
  signatures (these load-test instances do not)

```bash
curl -s -X POST http://144.76.171.226:9292/webhook/github \
  -H 'content-type: application/json' \
  -H 'x-github-event: workflow_job' \
  -d '{ "action": "queued",
        "installation": {"id": 1},
        "repository": {"full_name": "my-org/my-repo", "default_branch": "main"},
        "workflow_job": {"id": 1001, "labels": ["ubicloud-standard-2"], "runner_id": null} }'
# -> {"message":"GithubRunner[<ubid>] created"}
```

`action` semantics:
- `queued` — create a runner
- `in_progress` — runner picked up the job (needs a real `runner_id`)
- `completed` — deregister/destroy the runner (needs a real `runner_id`)

---

## 2. Fake GitHub API (read-only inspection)

Base URLs: `http://144.76.169.97:4567` (current) and `...:4568` (sorting-hat).

These are the real GitHub REST paths the control plane calls, served locally:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/app/installations/:id/access_tokens` | installation access token |
| `POST` | `/repos/:owner/:repo/actions/runners/generate-jitconfig` | register a runner (assigns `runner_id`) |
| `GET` | `/repos/:owner/:repo/actions/runners` | list runners |
| `GET` | `/repos/:owner/:repo/actions/runners/:id` | runner status (`busy`) |
| `DELETE` | `/repos/:owner/:repo/actions/runners/:id` | deregister a runner |
| `GET` | `/rate_limit` | rate limit (always high) |
| `GET` | `/repos/:owner/:repo/actions/runs` | queued runs (always empty) |
| `GET` | `/repos/:owner/:repo/actions/runs/:id[/attempts/:n]/jobs` | run jobs (always empty) |

Control/inspection endpoints (not part of the GitHub API):

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/_runners?repo=owner/name` | runners registered for a repo |
| `GET` | `/_state` | full state for this namespace |
| `POST` | `/_reset` | clear this namespace's state |

```bash
curl -s http://144.76.169.97:4567/_state
curl -s 'http://144.76.169.97:4567/_runners?repo=my-org/my-repo'
```

> State is **in-memory**: restarting the fake API clears it. Restart only while
> load is stopped.

---

## 3. Load generator control API

Base URL: `http://144.76.169.97:9299` (default; `--control-port` to change).
Available while a load run is in progress. See
[`github_runner_load_control_api.md`](./github_runner_load_control_api.md) for
the full reference.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/status` | current rate + per-target stats |
| `POST` | `/rate?value=N` | set rate in **jobs per minute** (JSON `{"rate":N}` also works) |
| `POST` | `/burst?count=N` | enqueue **N jobs immediately** to every target (default 100) |
| `POST` | `/stop` | stop the run early |

```bash
curl -s http://144.76.169.97:9299/status
curl -s -X POST 'http://144.76.169.97:9299/rate?value=3600'   # 3600/min (~60/s)
curl -s -X POST 'http://144.76.169.97:9299/burst?count=1000'  # 1000 jobs to each env
curl -s -X POST http://144.76.169.97:9299/stop
```

Example `/status`:
```json
{
  "rate_per_min": 1800.0,
  "stopping": false,
  "targets": [
    {"name":"current","url":"http://144.76.171.226:9292","repository":"my-org/my-repo",
     "events":{"workflow_job":{"sent":11609,"ok":11609,"failed":0}},
     "registered":5641,"label_counts":{"ubicloud-standard-2":...}}
  ]
}
```

---

## 4. Running a load test

On the load-sim VM:

```sh
ssh ubi@144.76.169.97
cd ~/load-sim

# ensure the fake API is up (both namespaces)
pgrep -af "[f]ake-github-api" || ./restart-fake-api

# run: rate is per minute and applied to each target (Poisson arrivals)
~/.local/bin/mise exec -- ruby github_runner_load --config targets.yml --rate 1800
```

Options: `--rate N` (per minute, per target), `--duration SECS`
(**default: infinite** — runs until stopped with `POST /stop`), `--concurrency N`,
`--no-progress` (queued-only load), `--dry-run`, `--control-port N`,
`--no-control`.

Since the run is infinite by default, end it with the control API:
```sh
curl -s -X POST http://144.76.169.97:9299/stop
```

---

## Notes and caveats

- **Rate is per minute and per target.** `--rate 1800` ≈ 30/s to *each*
  environment. Arrivals are Poisson, so per-second counts vary.
- **Default label mix** mirrors observed production traffic (x64):
  standard-2 63.8%, standard-4 23.3%, standard-8 7.1%, standard-16 5.6%,
  standard-30 0.17%, standard-60 0.01%. Override with a `labels:` map in the
  config. Because standard-30/60 are so rare, they appear only over long runs
  or high rates.
- **`sent` totals include progress events.** Each registered runner also emits
  `in_progress` + `completed`, so the reported `sent` is much larger than the
  queued rate. Use `--no-progress` to measure queued load only.
- **Redirect is required.** If a staging env shows `ok` webhooks but its
  namespace's `registered` stays flat, the app is not redirected — check
  `OCTOKIT_API_ENDPOINT` and restart **both** puma and `bin/respirate`.
- **Firewall.** Ports `4567`, `4568` (fake API) and `9299` (control API) must be
  reachable; `9299` is only needed from wherever you run curl.
