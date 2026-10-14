#!/usr/bin/env python3
"""Mock control planes for the scheduler dashboard.

Simulates two control planes that receive the *same* stream of fake GitHub
runner requests, and serves each one's metrics in the format described in
METRICS.md:

  current   models today's code path: every runner is its own strand.
           - start -> allocate_vm directly when the project is under quota
             (quota_available? with 0 extra usage, stale reads allow overshoot)
           - over quota -> wait_concurrency_limit, polling every rand(5..15)s,
             passing anyway once fleet utilization is <= 80%
           - allocate_vm -> Vm::Metal::Nexus#start, which on NoSpaceLeft naps
             clamp(30 / (1 + waited / 120), 5, 30) seconds and retries
  central  models the proposed centralized scheduler: one FIFO queue,
           dispatched whenever capacity changes, with the same quota and
           80% rules evaluated at dispatch time, small-job backfill, and a
           host reservation for a request that has waited too long to fit.

Both use the same fleet, the same placement function and the same arrivals,
so differences come only from how requests are queued and admitted.

Usage:
  python3 demo/scheduler-dashboard/mock_server.py            # http://localhost:8787
  python3 demo/scheduler-dashboard/inject.py --count 300     # burst into both
"""

import argparse
import json
import math
import random
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SIZES = [2, 4, 8, 16, 30]
SIZE_WEIGHTS = [0.35, 0.25, 0.20, 0.12, 0.08]
TICK = 0.25  # simulated seconds per step
LATENCY_WINDOW = 60
HOL_RESERVE_AFTER = 20  # central: reserve a host for a request older than this that does not fit
MAX_RESERVATIONS = 4
AGE_BUCKETS = [10, 30, 60, 120, 300, 600, 1800, 3600, None]  # upper bounds in seconds; None = above

# Thresholds today's code pages or acts on; see "Alerts" in METRICS.md.
CURRENT_ALERTS = [
    {"id": "no_capacity_page", "label": "NoCapacity page", "metric": "stage_oldest_seconds.waiting_capacity",
     "threshold": 3600, "severity": "page", "source": "prog/vm/metal/nexus.rb#start"},
    {"id": "boot_deadline_page", "label": "Boot deadline page", "metric": "stage_oldest_seconds.booting",
     "threshold": 600, "severity": "page", "source": "register_deadline(\"wait\", 10 * 60)"},
    {"id": "admission_gate", "label": "Admission gate", "metric": "fleet.utilization",
     "threshold": 0.8, "severity": "monitor", "source": "GithubRunnerNexus#wait_concurrency_limit"},
    {"id": "idle_recycle", "label": "Idle runner recycled", "metric": "stage_oldest_seconds.idle",
     "threshold": 310, "severity": "monitor", "source": "GithubRunnerNexus#wait"},
]
STATIC_FILES = {"/": "index.html", "/index.html": "index.html", "/dashboard.js": "dashboard.js"}


class Job:
    def __init__(self, template):
        self.id, self.project, self.vcpus, self.arrived, self.boot_seconds, self.run_seconds = template
        self.stage = "new"
        self.next_at = self.arrived
        self.host = None
        self.allocated_at = self.ready_at = self.done_at = None
        self.counted = False  # counts against the project's quota
        self.vm_created_at = None  # current: when the runner's VM was created
        self.first_entered = {"new": self.arrived}
        self.idle_until = None

    def enter(self, stage, now):
        # Stage age counts from the first time a request entered the stage,
        # so a request bouncing between admission and capacity keeps aging.
        self.stage = stage
        self.first_entered.setdefault(stage, now)


class Sim:
    alerts = CURRENT_ALERTS

    def __init__(self, name, display_name, args, seed):
        self.name = name
        self.display_name = display_name
        self.rng = random.Random(seed)
        self.free = [args.host_vcpus] * args.hosts
        self.total = args.host_vcpus * args.hosts
        self.demo_quota = args.demo_quota
        self.waiting = []  # in arrival order
        self.in_flight = []  # booting or running
        self.usage = {"demo": 0, "bg": 0}
        self.latency = deque()
        self.reservations = {}  # host index -> job id (central only)
        self.dirty = True
        self.last_dispatch = 0.0
        self.counters = dict.fromkeys(
            ["requests_received_total", "allocated_total", "started_total", "completed_total",
             "scheduling_checks_total", "order_inversions_total"], 0)

    # -- shared mechanics -------------------------------------------------

    def used(self):
        return self.total - sum(self.free)

    def quota_available(self, project, usage):
        # Project#quota_available?(type, 0): quota >= current usage. Background
        # traffic is spread over many projects, so it never hits a quota.
        return project != "demo" or self.demo_quota >= usage["demo"]

    def place(self, vcpus, exclude=()):
        fits = [i for i, f in enumerate(self.free) if f >= vcpus and i not in exclude]
        return self.rng.choice(fits) if fits else None

    def count_against_quota(self, job):
        if not job.counted:
            job.counted = True
            self.usage[job.project] += job.vcpus

    def allocate(self, job, host, now):
        self.free[host] -= job.vcpus
        job.host = host
        job.allocated_at = now
        job.ready_at = now + job.boot_seconds
        job.enter("booting", now)
        # An inversion: an older request that is no larger than this one is
        # still waiting, so it could have used this capacity instead.
        for other in self.waiting:
            if other.arrived >= job.arrived:
                break
            if other.vcpus <= job.vcpus:
                self.counters["order_inversions_total"] += 1
                break
        self.waiting.remove(job)
        self.in_flight.append(job)
        self.counters["allocated_total"] += 1
        self.latency.append((now, now - job.arrived))
        self.dirty = True

    def progress(self, now):
        still = []
        for job in self.in_flight:
            if job.stage == "booting" and now >= job.ready_at:
                # Registered with GitHub, waiting for it to hand over the job.
                job.enter("idle", now)
                job.idle_until = now + self.rng.uniform(1, 6)
            if job.stage == "idle" and now >= job.idle_until:
                job.enter("running", now)
                job.done_at = now + job.run_seconds
                self.counters["started_total"] += 1
            if job.stage == "running" and now >= job.done_at:
                self.free[job.host] += job.vcpus
                self.usage[job.project] -= job.vcpus
                self.counters["completed_total"] += 1
                self.dirty = True
                continue
            still.append(job)
        self.in_flight = still
        while self.latency and self.latency[0][0] < now - LATENCY_WINDOW:
            self.latency.popleft()

    def submit(self, template):
        job = Job(template)
        self.counters["requests_received_total"] += 1
        self.waiting.append(job)
        self.dirty = True
        return job

    # -- metrics -----------------------------------------------------------

    def metrics(self, now):
        ages = sorted(now - j.arrived for j in self.waiting)
        by_size = []
        for size in SIZES:
            sized = [now - j.arrived for j in self.waiting if j.vcpus == size]
            by_size.append({"vcpus": size, "waiting": len(sized), "oldest_seconds": round(max(sized), 1) if sized else 0})
        waits = sorted(w for _, w in self.latency)
        histogram = [0] * len(AGE_BUCKETS)
        for age in ages:
            histogram[next(i for i, le in enumerate(AGE_BUCKETS) if le is None or age <= le)] += 1

        def stage_oldest(jobs, stages):
            since = [min(j.first_entered[st] for st in stages if st in j.first_entered) for j in jobs if j.stage in stages]
            return round(now - min(since), 1) if since else 0

        return {
            "schema_version": 2,
            "scheduler": self.name,
            "display_name": self.display_name,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + f".{int(now % 1 * 1000):03d}Z",
            "stages": {
                "waiting_admission": sum(1 for j in self.waiting if j.stage == "admission"),
                "waiting_capacity": sum(1 for j in self.waiting if j.stage != "admission"),
                "booting": sum(1 for j in self.in_flight if j.stage == "booting"),
                "idle": sum(1 for j in self.in_flight if j.stage == "idle"),
                "running": sum(1 for j in self.in_flight if j.stage == "running"),
            },
            "stage_oldest_seconds": {
                "waiting_admission": stage_oldest(self.waiting, ("admission",)),
                "waiting_capacity": stage_oldest(self.waiting, ("new", "capacity")),
                "booting": stage_oldest(self.in_flight, ("booting",)),
                "idle": stage_oldest(self.in_flight, ("idle",)),
            },
            "waiting": {
                "count": len(ages),
                "oldest_seconds": round(ages[-1], 1) if ages else 0,
                "p50_seconds": round(pct(ages, 50), 1),
                "p95_seconds": round(pct(ages, 95), 1),
                "age_histogram": {"le": AGE_BUCKETS, "counts": histogram},
            },
            "by_vcpus": by_size,
            "latency": {
                "window_seconds": LATENCY_WINDOW,
                "queue_to_allocated": {
                    "count": len(waits),
                    "p50_seconds": round(pct(waits, 50), 1),
                    "p95_seconds": round(pct(waits, 95), 1),
                    "p99_seconds": round(pct(waits, 99), 1),
                },
            },
            "counters": dict(self.counters),
            "fleet": {"vcpus_total": self.total, "vcpus_used": self.used()},
            "alerts": self.alerts,
        }


class CurrentSim(Sim):
    def submit(self, template):
        job = super().submit(template)
        if self.quota_available(job.project, self.usage):
            self.to_allocator(job, job.arrived)
        else:
            # start hops to wait_concurrency_limit, which runs right away.
            job.enter("admission", job.arrived)
            job.next_at = job.arrived

    def to_allocator(self, job, now):
        # allocate_vm creates the VM, and Vm::Metal::Nexus#start tries to
        # place it immediately.
        # NoCapacity measures from vm.created_at, which is this moment.
        job.enter("capacity", now)
        job.vm_created_at = now
        self.count_against_quota(job)
        self.try_place(job, now)

    def try_place(self, job, now):
        self.counters["scheduling_checks_total"] += 1
        host = self.place(job.vcpus)
        if host is not None:
            self.allocate(job, host, now)
        else:
            waited = now - job.vm_created_at
            job.next_at = now + min(max(30.0 / (1 + waited / 120.0), 5), 30)

    def step(self, now):
        self.progress(now)
        # Each strand reads utilization and quota usage in its own
        # transaction, so checks in the same instant see the same stale view.
        usage_snapshot = dict(self.usage)
        util_snapshot = self.used() / self.total
        for job in [j for j in self.waiting if j.next_at <= now]:
            if job.stage != "admission":
                self.try_place(job, now)
                continue
            self.counters["scheduling_checks_total"] += 1
            if self.quota_available(job.project, usage_snapshot) or util_snapshot <= 0.8:
                self.to_allocator(job, now)
            else:
                job.next_at = now + self.rng.uniform(5, 15)


class CentralSim(Sim):
    def step(self, now):
        self.progress(now)
        # Dispatch on every capacity change or arrival; the once-a-second pass
        # only exists to notice requests crossing the reservation threshold.
        if self.dirty or now - self.last_dispatch >= 1.0:
            self.dispatch(now)

    def dispatch(self, now):
        self.dirty = False
        self.last_dispatch = now
        util = self.used() / self.total
        # Capacity only shrinks during a pass, so once a size fails to fit,
        # every request at least that large fails too and is not retried.
        smallest_failed = math.inf
        for job in list(self.waiting):
            if sum(self.free) < SIZES[0]:
                break
            if not self.quota_available(job.project, self.usage) and util > 0.8:
                job.enter("admission", now)
                continue
            reserved_by_others = {h for h, jid in self.reservations.items() if jid != job.id}
            own = [h for h, jid in self.reservations.items() if jid == job.id]
            host = None
            if own and self.free[own[0]] >= job.vcpus:
                host = own[0]
            elif job.vcpus < smallest_failed:
                self.counters["scheduling_checks_total"] += 1
                host = self.place(job.vcpus, reserved_by_others)
                if host is None:
                    smallest_failed = job.vcpus
            if host is not None:
                for h in own:
                    del self.reservations[h]
                self.count_against_quota(job)
                self.allocate(job, host, now)
                util = self.used() / self.total
                continue
            job.enter("capacity", now)
            if not own and now - job.arrived > HOL_RESERVE_AFTER and len(self.reservations) < MAX_RESERVATIONS:
                # Hold the emptiest unreserved host for this request so smaller
                # requests stop backfilling it and it drains to fit.
                candidates = [i for i in range(len(self.free)) if i not in self.reservations]
                if candidates:
                    self.reservations[max(candidates, key=lambda i: self.free[i])] = job.id


def pct(sorted_values, p):
    if not sorted_values:
        return 0.0
    k = (len(sorted_values) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


class World:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.rng = random.Random(args.seed)
        self.bg_rate_per_min = args.rate
        self.current = CurrentSim("current", "Current · per-runner polling", args, args.seed + 1)
        self.central = CentralSim("central", "Central scheduler", args, args.seed + 1)
        self.now = time.time() - args.warmup
        self.next_bg = self.now
        self.pending = []  # injected templates not yet arrived
        self.next_id = 0

    def template(self, project, arrived, vcpus=None, run=(60, 240)):
        self.next_id += 1
        size = vcpus or self.rng.choices(SIZES, SIZE_WEIGHTS)[0]
        return (self.next_id, project, size, arrived, self.rng.uniform(15, 30), self.rng.uniform(*run))

    def deliver(self, template):
        self.current.submit(template)
        self.central.submit(template)

    def advance(self):
        self.now += TICK
        while self.bg_rate_per_min > 0 and self.next_bg <= self.now:
            self.deliver(self.template("bg", self.next_bg))
            self.next_bg += self.rng.expovariate(self.bg_rate_per_min / 60)
        if self.bg_rate_per_min <= 0:
            self.next_bg = self.now
        due = [t for t in self.pending if t[3] <= self.now]
        if due:
            self.pending = [t for t in self.pending if t[3] > self.now]
            for t in due:
                self.deliver(t)
        self.current.step(self.now)
        self.central.step(self.now)

    def inject(self, count, vcpus=None, spread=0.0):
        with self.lock:
            for i in range(count):
                arrived = self.now + (spread * i / count if spread else 0)
                self.pending.append(self.template("demo", arrived, vcpus, run=(60, 180)))
        return {"injected": count, "vcpus": vcpus or "mixed", "spread_seconds": spread}

    def run(self):
        with self.lock:
            while self.now < time.time():
                self.advance()
        while True:
            time.sleep(TICK / self.args.speed)
            with self.lock:
                self.advance()


def make_handler(world, upstreams):
    root = Path(__file__).resolve().parent

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, status, body, content_type="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            self.wfile.write(data)

        def do_OPTIONS(self):
            self.send(204, b"", "text/plain")

        def do_GET(self):
            path = self.path.split("?")[0]
            side = path.split("/")[1]
            if path in ("/current/scheduler/metrics", "/central/scheduler/metrics") and upstreams.get(side):
                return self.proxy(upstreams[side])
            if path in ("/current/scheduler/metrics", "/central/scheduler/metrics"):
                with world.lock:
                    sim = world.current if path.startswith("/current") else world.central
                    return self.send(200, sim.metrics(world.now))
            if path in STATIC_FILES:
                name = STATIC_FILES[path]
                ctype = "text/html; charset=utf-8" if name.endswith(".html") else "text/javascript; charset=utf-8"
                return self.send(200, (root / name).read_bytes(), ctype)
            self.send(404, {"error": "not found"})

        def proxy(self, url):
            # Serving a real control plane's metrics from this origin keeps
            # the dashboard working over HTTPS (no mixed content) and CORS.
            try:
                with urllib.request.urlopen(url, timeout=3) as resp:
                    return self.send(200, resp.read())
            except (urllib.error.URLError, OSError) as e:
                return self.send(502, {"error": f"upstream {url}: {e}"})

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                return self.send(400, {"error": "invalid JSON"})
            path = self.path.split("?")[0]
            if path == "/inject":
                count = int(body.get("count", 100))
                vcpus = body.get("vcpus")
                if vcpus is not None and int(vcpus) not in SIZES:
                    return self.send(400, {"error": f"vcpus must be one of {SIZES}"})
                return self.send(200, world.inject(count, vcpus and int(vcpus), float(body.get("spread", 5))))
            if path == "/load":
                with world.lock:
                    if "delta_per_min" in body:
                        world.bg_rate_per_min += float(body["delta_per_min"])
                    else:
                        world.bg_rate_per_min = float(body.get("rate_per_min", world.bg_rate_per_min))
                    world.bg_rate_per_min = max(0.0, world.bg_rate_per_min)
                return self.send(200, {"rate_per_min": world.bg_rate_per_min})
            self.send(404, {"error": "not found"})

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8787)
    p.add_argument("--hosts", type=int, default=24)
    p.add_argument("--host-vcpus", type=int, default=64)
    p.add_argument("--rate", type=float, default=46, help="background requests per minute (~65%% fleet utilization)")
    p.add_argument("--demo-quota", type=int, default=600, help="vCPU quota of the project that receives injected bursts")
    p.add_argument("--speed", type=float, default=1.0, help="simulated seconds per real second")
    p.add_argument("--warmup", type=float, default=600, help="simulated seconds to run before serving")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--current-url", help="serve /current/scheduler/metrics from this real endpoint instead of the simulation")
    p.add_argument("--central-url", help="serve /central/scheduler/metrics from this real endpoint instead of the simulation")
    args = p.parse_args()
    upstreams = {"current": args.current_url, "central": args.central_url}

    world = World(args)
    threading.Thread(target=world.run, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(world, upstreams))
    print(f"Dashboard:  http://localhost:{args.port}/")
    for side in ("current", "central"):
        source = f"proxied from {upstreams[side]}" if upstreams[side] else "simulated"
        print(f"Metrics:    http://localhost:{args.port}/{side}/scheduler/metrics ({source})")
    print(f"Inject:     python3 {Path(__file__).parent / 'inject.py'} --count 300")
    server.serve_forever()


if __name__ == "__main__":
    main()
