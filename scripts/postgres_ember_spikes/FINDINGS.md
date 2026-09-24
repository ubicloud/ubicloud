# Postgres Ember spikes: measurements and design deltas

Results of the section 12 spikes from the Postgres Ember design, run on real
hardware before any production code. Every number below was produced by the
scripts in this directory; the raw JSON is written to `out/`.

**Test host.** Hetzner dedicated server, AMD Ryzen 9 7950X3D (16 cores / 32
threads), 126 GiB RAM, NVMe, Ubuntu 24.04, kernel 6.8. cloud-hypervisor 53.0,
EDK2 CLOUDHV-202311, ubiblk 0.5.1. Registered in a development control plane as
the only `VmHost`, prepared the way the metal e2e suite does.

**What was actually built.** An ember root image derived from the
`ubuntu-noble` boot image (read-only root with `overlayroot=tmpfs`, PostgreSQL
18 from PGDG, static network, cloud-init disabled, a vsock guest agent -- which
2.14 then removes); a
1.5 GiB PGDATA image holding a freshly `initdb`'d cluster; per-slot network
namespaces with the appendix E nftables ruleset; detachable ubiblk volumes;
template snapshot and restore. Scripts drive cloud-hypervisor and ubiblk
directly, so no control-plane strand scheduling is in the measurements.

Caveats: the "second host" in the transfer spikes is a second storage root and
slot on the same machine, so network transfer times are loopback-optimistic
(the fixed costs below are not). The guest agent is Python rather than the
proposed static Go binary. Most spikes run components as root; s8 covers the
per-slot unix user the design actually specifies.

---

## 1. Headline numbers

Restore of a 512 MiB template to the guest agent answering its first command,
p50 of 15 runs:

| `memory_restore_mode` | restore complete | agent reachable | first command |
|---|---|---|---|
| `copy` | 152 ms | 160 ms | **161 ms** |
| `copy` + `prefault=on` | 254 ms | 255 ms | 257 ms |
| `ondemand` | 26 ms | 42 ms | **62 ms** |
| `ondemand` + `prefault=on` | rejected by cloud-hypervisor | | |

S1's pass condition (p50 ≤ 250 ms) is met by both usable modes. `ondemand` is
2.6x faster and is the recommendation.

End-to-end operations, measured from the harness:

| Operation | Design estimate | Measured (p50) |
|---|---|---|
| Claim a warm blank (`configure` on a running ember) | ~60 ms | **34 ms** |
| Cold create (new volume from the PGDATA raw source) | 440–640 ms | **525 ms** |
| Pause (clean PostgreSQL shutdown, detach, destroy VM) | < 2 s | **222 ms** |
| Resume, volume local to the host | 420–720 ms | **519 ms** |
| Resume, volume on another host (remote stripe source) | 520–1,020 ms | 1,957 ms stock, **555 ms** with the ubiblk changes in 2.3 |
| Resume, volume in object storage (archive source) | 690–1,590 ms | **1,548 ms** |

Density, one host, each ember running its own PostgreSQL:

| | Measured |
|---|---|
| Embers running concurrently | **103** (host not saturated) |
| Full create latency, p50 / p95 / max across the ramp | 492 / 511 / 520 ms |
| Create latency with 100 already running | 493–514 ms (no degradation) |
| Host memory per ember | **532 MiB** (cloud-hypervisor 513 + ubiblk 27) |
| Disk per paused volume | ~30 MiB actual (2 GiB sparse) |
| Host load average with 103 idle PostgreSQL instances | 1.54 |

Control plane, measured against the real Clover stack under Puma:

| | Design budget | Measured (p50) |
|---|---|---|
| Whole API request (auth, transaction, insert, audit, serializer) | part of 15 ms | **11 ms** |
| Placement query | part of 15 ms | **0.5 ms** |
| HTTPS to emberd (keep-alive) | 10 ms | **0.5 ms** |
| Implied warm-pool create, end to end | < 150 ms | **~46 ms** |

Correctness, which is where the spikes were most useful:

| Property | Result |
|---|---|
| Data survives pause and same-host resume | verified over repeated cycles |
| Data survives a move to another host | verified, and host B keeps working once the source is gone |
| Data survives an archive round trip | **PGDATA tree byte-identical** |
| Restored clones produce distinct randomness | only with `post_restore`; without it clones are **identical** |
| Ember survives an unclean pause | only with a **journalled** PGDATA filesystem |
| A guest can reach anything it should not | no: egress and cross-slot both blocked |

---

## 2. Findings that change the design

### 2.1 Snapshot hygiene is worth more than the restore mode (blocking)

The first template was snapshotted as soon as the guest agent answered, about
8 s into boot, while systemd was still starting units. Every restored clone
then replayed the tail of boot: `ondemand` first-command latency was **600 ms**
and `copy` was **700 ms**, and the guest's own execution time accounted for
essentially all of the gap.

Waiting for the guest to finish booting and go quiet before pausing dropped
those to **62 ms** and **161 ms** respectively — a ~500 ms saving, larger than
the difference between any two restore modes.

*Delta:* section 4.3 step 3 should make quiescence a hard gate, not an implicit
assumption: wait until `systemctl is-system-running` leaves `starting` /
`initializing` **and** `systemctl list-jobs` is empty for several consecutive
samples, then settle, `sync`, and only then pause. `build_template.rb`
implements this. A template built from a busy guest is a silent 10x latency
regression with no other symptom, so this deserves an assertion and a metric.

### 2.2 Use `ondemand`, and drop the `prefault` fallback

Section 10 proposes falling back to `memory_restore_mode=ondemand` if copy is
too slow, and mentions prefault. Measured:

- `prefault=on` **cannot** be combined with `ondemand` — cloud-hypervisor 53
  rejects the config outright: `'prefault' cannot be combined with
  'memory_restore_mode=ondemand'`.
- `prefault=on` with `copy` makes restore ~100 ms *worse* and helps nothing
  afterwards.
- cloud-hypervisor 53 already runs a background prefault after an `ondemand`
  restore; its log reports e.g. `prefault done in 433ms — prefaulted=121060
  served=10012 total=131072`, i.e. only ~8 % of pages were demand-faulted by
  the guest and the rest were filled in behind it.

*Delta:* make `ondemand` the default in section 5.3 and delete the prefault
option from section 10.

**Operational prerequisite, measured.** `ondemand` needs userfaultfd, and the
design runs cloud-hypervisor as a per-slot unix user rather than as root. On a
stock Ubuntu 24.04 host `/dev/userfaultfd` is `0600 root:root` and
`vm.unprivileged_userfaultfd=0`. Restoring the same template from the same slot
under four combinations:

| Runs as | userfaultfd policy | Mode | Result |
|---|---|---|---|
| root | relaxed | `ondemand` | ok, 56 ms |
| slot user (uid 60500) | relaxed | `ondemand` | **ok, 62 ms** |
| slot user | Ubuntu default | `ondemand` | **fails** |
| slot user | Ubuntu default | `copy` | ok, 163 ms |

The failure is precisely the expected one:

```
Fatal error: VmRestore(... OnDemandRestore(Create(PermissionDenied)))
  4: On-demand restore failed
  5: Failed to create userfaultfd
  6: Operation not permitted (os error 1)
```

So the design's privilege model is fine — running as the slot user costs about
6 ms — but `ondemand` is gated on host policy. `EmberHost` prep must set
`vm.unprivileged_userfaultfd=1` or ship a udev rule widening
`/dev/userfaultfd`, and that should be a checked precondition rather than an
assumption, because the fallback is silent: `copy` still works, just 2.6x
slower. Note `/dev/kvm` and `/dev/vhost-vsock` are both `0660 root:kvm` by
default, so the slot user needs to be in `kvm` for the vsock agent to work —
one more thing for prep-host beyond what section 5.2 lists.

### 2.3 The remote stripe source's startup cost is a Nagle stall, and it is fixed

Starting a ubiblk backend whose stripe source is `remote` took **1.34 s before
the vhost socket existed**, on loopback, regardless of volume size or autofetch
setting, and on every start rather than just the first. That was 68 % of the
cross-host resume and by itself blew the "under 2 s to first query" target.

**It is not the handshake being expensive.** Sweeping the connection count
shows a perfectly linear per-connection cost:

| `connections` | backend start | per connection |
|---|---|---|
| 1 | 98 ms | 98 ms |
| 4 | 349 ms | 87 ms |
| 16 | 1,341 ms | 84 ms |
| 32 | 2,665 ms | 83 ms |

And a packet capture of a single connection shows where those 84 ms go — the
protocol work finishes in 2.2 ms and the rest is two stalls on the Linux
delayed-ACK timer:

```
   2.16  +   0.03  Flags [P.], seq 151:181 ...
  42.82  +  40.67  Flags [.], ack 181 ...            <-- STALL
  43.05  +   0.12  Flags [P.], seq 214:244 ...
  83.82  +  40.78  Flags [.], ack 244 ...            <-- STALL
  83.84  +   0.02  Flags [P.], seq 244:3382 ...      (the 3 KB of metadata)
```

ubiblk never sets `TCP_NODELAY`, on either end. Both the hello handshake and
the metadata fetch are write-write-read exchanges — the peer writes a status
byte and then a second small record — which is the classic pattern that
deadlocks Nagle against the other side's delayed ACK. Two exchanges, two 40 ms
stalls. Dialing the pool in a sequential loop
(`src/stripe_source/builder.rs`) then multiplies it by `connections`, which
defaults to 16.

Note the bulk fetch path is *not* affected: stripe responses are large enough
that Nagle has nothing to hold back. This is purely a small-message problem,
which is why it hides as a fixed startup cost.

**Fix, implemented and measured.**
A 36-line change against ubiblk v0.5.1: `set_nodelay(true)` on the client dial
and on the accepted server socket, and dialing the connection pool concurrently
instead of one at a time. Both halves are merged into ubiblk's main
(ubicloud/ubiblk#508 and #509) but not yet released; the numbers here were
measured with them applied to v0.5.1. Building it and re-running the same sweep:

| `connections` | stock | patched | speedup |
|---|---|---|---|
| 1 | 98 ms | 19 ms | 5x |
| 4 | 349 ms | 20 ms | 17x |
| 16 | **1,341 ms** | **21 ms** | **65x** |
| 32 | 2,665 ms | 22 ms | 121x |

Startup is now essentially flat in the connection count, which is what you
would expect once the dials are concurrent and none of them stalls.



End to end, cross-host resume with the data verified on arrival:

| | first query |
|---|---|
| stock, `autofetch=true` | 1,957 ms |
| patched, `autofetch=true` | 1,086 ms |
| patched, `autofetch=false` | **657 ms** |

*Delta:* land it in ubiblk. With it, section 6.1 no longer needs to
prefer the archive over the remote source, and cross-host resume comes in under
the design's own 520–1,020 ms estimate rather than at twice it.

**A second change, on top: deferring catch-up.** With the stall gone, the
remaining gap between `autofetch=false` (657 ms) and `autofetch=true`
(1,086 ms, both measured before the agent fix in 2.10) is the background catch-up of 1.5 GiB competing with PostgreSQL's
own startup I/O. Resuming wants both things: the tenant's first query as soon
as possible, *and* the volume caught up so it stops depending on the source
host. Those only compose if the running backend can be told to start fetching
after the workload is up — and ubiblk's RPC socket only accepted `status`,
`queues` and `stats`, while the backend cannot be restarted under a live VM
(cloud-hypervisor marks the device `NEEDS_RESET`).

ubicloud/ubiblk#510 adds a `start_autofetch` RPC, which sends a
`StartAutofetch` request down the background worker's own channel; the worker
then queues every stripe. Stripes already fetched are dropped by the existing
`handle_fetch_request`, so it is safe to call after the volume has been serving
lazily. The numbers below were measured with an earlier version, which set a
latch the fetcher checked on each poll instead. That version had a flaw the
numbers do not show: an idle worker waits in `recv()`, so the latch was not
read until some other request woke it. Resumed, answered one query and left
alone (`IDLE=1` in `s10_deferred_autofetch.rb`), an ember began catching up only
when PostgreSQL's own background writes happened to arrive -- 30.85 s after
the RPC, against 1.0 s with the request on the channel. Busy, the two are the
same.

Measured end to end — resume on another host, `autofetch=false`, then the RPC:

| Step | |
|---|---|
| First query | **555 ms** (24 of 1,536 stripes fetched — genuinely lazy) |
| `start_autofetch` | `{"autofetch": "requested"}` |
| Caught up | **1.02 s later**, while continuing to serve queries |
| Source host stopped | data still correct; the volume is independent |

So the ember is usable at 555 ms and free of the source host about 1.6 s
after resume, against 1,957 ms merely to first query on stock ubiblk.

*Delta:* section 7.2's resume path should place with `autofetch=false` and have
`Prog::Storage::DetachableVolumeNexus` call `start_autofetch` once the ember
is running, then poll `status` for `fetched == source` exactly as
`VmStorageVolume#caught_up?` already does.

**All three changes** were first measured as patches applied to v0.5.1, and
there, with the earlier latch, they passed ubiblk's suite (473 tests, including
4 new ones covering the latch and the RPC) and `cargo fmt --all --check`;
`clippy -D warnings` reported the same 9 errors as pristine v0.5.1 on this
toolchain, so none added any.

### 2.4 Archive restore is faster than cross-host restore, and is byte-correct

The archive leg was the one with a real correctness question. A NEW volume is
seeded from the PGDATA raw image with `copy_on_read`, so most of its stripes
are never written and often never even read — at pause, one volume had fetched
only 85 of 1,536 source stripes. If `archive` uploaded only written stripes,
restoring elsewhere would leave holes exactly where the initdb'd cluster lives.

It does not. Archiving a paused volume, deleting the local copy, and restoring
on another slot from object storage produced a **byte-identical PGDATA tree**
(md5 over every file, PostgreSQL stopped on both ends), and the SQL-level row
count and checksum matched.

| | Measured |
|---|---|
| Archive a 2 GiB volume holding ~130 MB of data | 1.6 s |
| Objects written / bytes in bucket | 366 objects, 69.3 MiB (zstd-3, encrypted) |
| Volume create against an archive source | 38 ms |
| Attach (mount, reading through S3) | 558 ms |
| First query | **1,530 ms** |

*Delta:* section 6.3 can keep its plan unchanged; add the byte-level round trip
to the test suite, because the property depends on ubiblk fetching unwritten
stripes from the raw source at archive time and would break silently if that
changed.

### 2.5 Cloned randomness is as dangerous as the design says, and the fix works

Three clones restored from one template, with no `post_restore`, produced the
**identical** first value from `/proc/sys/kernel/random/uuid`, and two of the
three produced identical `/dev/urandom` output:

```
clone 0: a46c60bb-9fc4-46a7-861a-16986cff0be2 ... b794e4ef6d33d558
clone 1: a46c60bb-9fc4-46a7-861a-16986cff0be2 ... dad8240454fc0ca1
clone 2: a46c60bb-9fc4-46a7-861a-16986cff0be2 ... b794e4ef6d33d558
```

With `post_restore` (host nonce + `/dev/hwrng` mixed via `RNDADDENTROPY`, then
`RNDRESEEDCRNG`), all samples across all clones were distinct.

*Delta:* none to the design's intent — but this must be a gating test in CI, and
`post_restore` must be ordered strictly before anything that can derive a
secret. Note that cloud-hypervisor provides no VM Generation ID, so there is no
kernel-side safety net; the agent is the only thing standing between the design
and every ember sharing SCRAM salts and TLS keys.

Related, as predicted by section 9: `/etc/machine-id` and
`/proc/sys/kernel/random/boot_id` are identical across clones. Nothing in this
stack keys on them, but anything added later must not.

Clock: cloud-hypervisor 53 advances the guest clock across the paused interval,
and residual drift measured **-21 to -26 ms**. The agent's 500 ms correction
threshold therefore never fires in practice; it is a genuine safety net rather
than a routine step.

### 2.6 Isolation behaves as designed

- Every slot runs the identical guest MAC and IPv6 (`02:5b:0c:00:00:02`,
  `fd00:b1c:5b0c::2`) and nothing leaks: a ping from slot A's namespace to slot
  B's public address is blocked.
- Guest egress is fully blocked — both ICMPv6 to a neighbouring slot and a TCP
  connect to a public IPv4 address fail.
- The gateway path works: from the host's root namespace, connecting to the
  slot's public address on 5432 is DNATed to the guest, which reports
  `inet_server_addr() = fd00:b1c:5b0c::2`. Addresses are stable per slot, so no
  per-ember DNS or routing change is needed.

### 2.7 The PGDATA filesystem needs its journal (blocking)

Section 4.1 builds the PGDATA image with `mkfs.ext4 -O ^has_journal`. An ember
is killed abruptly by definition — host loss, OOM, a pause whose clean shutdown
timed out — so this is the one workload where the journal earns its keep.

Three rounds of killing an ember mid-write, per filesystem variant and per
failure mode (`vm_kill`: cloud-hypervisor killed, ubiblk still flushing;
`host_crash`: both killed):

| PGDATA filesystem | Failure mode | Rounds survived |
|---|---|---|
| journalled (default `mkfs.ext4`) | VM killed | **3 / 3** |
| journalled | host crash | **3 / 3** |
| `-O ^has_journal` | VM killed | **0 / 1** |
| `-O ^has_journal` | host crash | **0 / 1** |

With the journal, every round recovered: `fsck -fp` corrected the filesystem
(exit 1, "errors corrected"), PostgreSQL ran WAL recovery, every committed row
was still present and a full scan of the table was clean. The in-flight
uncommitted transaction rolled back, as it should.

Without the journal, PostgreSQL never came back after the very first unclean
kill, in both failure modes. (The table was produced twice: once before and
once after the readiness probe below was corrected, with the same outcome, so
the comparison is not an artefact of that bug.) The most instructive failure
was the one seen earlier in development: the filesystem was inconsistent but
still *mounted* cleanly, and PostgreSQL only fell over later, during recovery,
with

```
PANIC: could not rename file "pg_logical/replorigin_checkpoint.tmp"
  to "pg_logical/replorigin_checkpoint": Structure needs cleaning
```

*Delta:* drop `-O ^has_journal` from section 4.1. The I/O it saves is not worth
losing the ember. Two related points:

- **Do not wait for `mount` to fail before running fsck.** An inconsistent ext4
  usually mounts, and the damage surfaces later as `EUCLEAN` from inside
  PostgreSQL. The `clean_shutdown` column the design already carries on
  `detachable_volume` (6.1) should be passed to the guest on `attach`, and the
  agent should run `fsck -fp` up front whenever the previous detach was
  unclean. The agent here does exactly that.
- **`postmaster.pid` is not usable as a readiness signal at all here.** It
  survives an unclean pause still reading `ready`, so a naive poll reports
  PostgreSQL up before the new postmaster exists. Guarding on "has the file
  been rewritten" is not enough either: a restored clone reproduces the guest
  process table, so the new postmaster is handed the *same pid* as the stale
  file records, and with second-granularity start times the two files come out
  byte-identical. Observed directly:

  ```
  stale='723\n/data/pgdata\n1790033202\n5432\n...\nready   \n'
  last ='723\n/data/pgdata\n1790033202\n5432\n...\nready   \n'
  ```

  The agent therefore speaks enough of the startup protocol over the unix
  socket to distinguish "accepting connections" from `57P03` "still starting
  up". This is a nice illustration of the general hazard in 2.5: anything in a
  restored clone that assumes uniqueness of a host-local identifier — pids
  included — is wrong by construction.

### 2.8 Template size: 384 MiB is the right answer to decision 1

Section 14 asks whether 384 MiB would do instead of 512 MiB. Five full
create cycles per size, `ondemand`, plus a workload of 2 million rows and an
index build:

| Template | restore -> agent hello (p50) | cloud-hypervisor RSS | 2M-row insert + index build |
|---|---|---|---|
| 512 MiB | 73.5 ms | 517.8 MiB | ok |
| 384 MiB | 77.4 ms | 389.8 MiB | ok |
| 256 MiB | 74.8 ms | 261.8 MiB | **postmaster killed during the index build** |

Two things fall out. First, **restore latency is flat across template size** —
which makes sense with `ondemand`, since nothing proportional to memory size
happens on the critical path. Shrinking the template buys density, not speed;
under `copy` it would buy both, but `copy` is slower everywhere. Second,
256 MiB is too small to be honest about a "1 GB of data" tier: a routine index
build over 2 million rows loses the postmaster.

*Delta:* take decision 1 as 384 MiB. It cuts per-ember memory by a quarter
(about 128 MiB, so roughly 120 rather than 90 embers on a 64 GB host) at no
latency cost and with the sample workload still comfortable.

### 2.9 Density: budget the whole template, free page reporting does not help

With `--balloon size=0,free_page_reporting=on` in the template and 103 idle
embers running, host memory worked out to **532 MiB per ember**:
cloud-hypervisor 513 MiB RSS plus ubiblk 27 MiB. In other words the full
512 MiB guest is resident and nothing is reclaimed — cloud-hypervisor 53's
background prefault after an `ondemand` restore touches every page, and the
guest never has enough memory pressure to report pages back.

Section 11's expectation that "idle guests settle near 150 to 200 MB RSS" is not
borne out. On a 64 GB host with 48 GB reserved for guests, 532 MiB each gives
about **90 running embers**, close to the design's target of 100 but with no
headroom from reporting.

*Delta:* plan capacity at full template size. This is what makes decision 1
worth taking (see 2.8): a 384 MiB template measured at 390 MiB resident.
Alternatively investigate whether
suppressing the background prefault (`ondemand` without it) lets reporting
work — but that trades against first-touch latency and is not exposed as a
separate knob today.

Encouragingly, latency did not degrade with occupancy at all: full create was
492 ms p50 / 511 ms p95 across the entire ramp from 1 to 100, and three extra
embers created with 100 already running took 493–514 ms. S5's pass
condition (p95 restore under 1 s at 90 % occupancy) is met comfortably.

### 2.10 Smaller corrections

- **Pause must call `vmm.shutdown`.** `ch-remote shutdown` (appendix D) stops
  the VM but leaves the VMM process alive holding the API socket and the slot;
  pause took 10 s and then needed a kill. Using `vmm.shutdown` brought the whole
  pause to 222 ms. Appendix D should be corrected.
- **Find the hot-plugged disk by serial, not by udev symlink.** Waiting for
  `/dev/disk/by-id/virtio-cldata` costs ~70 ms after hot-plug; matching
  `/sys/block/vd*/serial` against the ubiblk `device_id` costs ~24 ms. Worth
  ~46 ms on every create and resume.
- **Hot-plug itself is free.** `PUT /api/v1/vm.add-disk` with
  `vhost_user=on` after an `ondemand` restore returns in **0.8 ms** and always
  worked. Section 12's fallback plan (bake the data disk into the template) is
  not needed.
- **`ch-remote` is too expensive to poll with.** Each invocation is a process
  spawn of the same order as the thing being measured; `emberd` should speak
  to the API socket directly, as `lib/ember.rb` does.
- **Stop the VM before stopping the backend.** If the ubiblk socket disappears
  under a running VM, cloud-hypervisor retries for a full minute and then marks
  the device `NEEDS_RESET`. The design's ordering (remove-device, then stop the
  backend) is correct and is load-bearing.
- **PostgreSQL start is now the largest single item** in create and resume at
  ~280 ms, plus ~35 ms for the `ALTER ROLE`. `pg_ctl -w` polls on a 100 ms
  timer, so the agent uses `pg_ctl -W` and does its own readiness probe, which
  saved ~30 ms. That probe must be a real PQping over the unix socket, not a
  read of `postmaster.pid` — see 2.7. The warm pool removes this cost from
  create but not from resume.
- **Do not busy-poll a starting postmaster.** Replacing the `postmaster.pid`
  read with a real PQping (2.7) quietly cost ~85 ms on every create and resume:
  once the postmaster is listening it forks a backend for *every* connection,
  including the ones it rejects with `57P03` while it finishes recovery, so a
  1 ms ping loop makes the guest fork hundreds of processes during exactly the
  window being shortened. Waiting for the socket file to appear is free, so the
  agent polls that tightly and only pings on a 10 ms timer. `pg_ctl` went from
  ~365 ms back to ~280 ms. This was caught only because the local-path numbers
  drifted between two runs of the same spike; it is a good argument for the
  suite tracking latency over time rather than checking it once.

- **A 512 MiB ember is easy for a tenant to OOM.** `SELECT
  md5(string_agg(...))` over a 157 MB aggregate killed the postmaster. Not a
  design flaw — the blast radius is one ember — but the docs should say so,
  and it argues against shrinking the template too far.
- **Ember hosts must not park all RAM in 1 GiB hugepages.** Ember VMs use
  `shared=on`, which comes from normal pages; the control plane's host prep had
  119 of 126 GiB in the hugepage pool, leaving 6 GiB. `EmberHost` prep needs
  its own hugepage policy.
- **ubiblk version.** The control plane installed v0.4.2 on this host; the
  design assumes 0.5.1, which is what `remote-stripe-server` requires. Whatever
  pins the version for ember hosts needs to be explicit about it.

---

### 2.11 The synchronous control-plane path fits, but must not hold the DB connection across the host call

Section 7.2 runs create and resume inside the API request, budgeting 15 ms for
"API, DB, placement" and 10 ms for the HTTPS call to emberd. None of that had
been measured. Measured against the real Clover stack under Puma
(`RACK_ENV=production`, 15 threads), using `POST firewall` as a create-shaped
endpoint that opens a transaction, inserts and writes an audit log:

| | Design budget | Measured (p50) |
|---|---|---|
| Whole request: auth, routing, transaction, insert, audit, serializer | part of 15 ms | **11 ms** |
| Placement query (hosts in a location, ordered by capacity) | part of 15 ms | **0.5 ms** |
| HTTPS to emberd, keep-alive connection | 10 ms | **0.5 ms** |
| HTTPS to emberd, fresh TLS handshake each time | – | 1.9 ms |
| Minting the HS256 JWT | – | 0.03 ms |
| `GET /project` (auth plus one row) | – | 3.8 ms |

So the per-request arithmetic works comfortably: about **11.5 ms of control
plane** plus the host, which puts a warm-pool create (34 ms on the host, 2.8)
at roughly **46 ms end to end** against a 150 ms target. Keep-alive to emberd
is worth having — 0.5 ms against 1.9 ms — but it is not the thing that matters.

**What does matter is the transaction.** The design wraps the whole thing in
`DB.transaction { ... FOR UPDATE ... host call ... }`, which holds a pooled
database connection for the entire duration of the host call. Modelling that
directly, 20 concurrent operations on *independent* embers:

| Pool | Host call | p50 | p99 | Throughput |
|---|---|---|---|---|
| 4 (the default `db_pool_web`) | 50 ms | 52 ms | 1,097 ms | 76/s |
| 4 | 500 ms | 506 ms | 10,624 ms | 7.9/s |
| 15 | 500 ms | 503 ms | 3,032 ms | 20/s |
| 40 | 500 ms | 502 ms | 565 ms | 39/s |

p50 is always just the host call, so nothing looks wrong until the tail: with
the default pool of **4 connections against 15 Puma threads**, a cold create
holding the connection for 500 ms caps the entire web process at about 8
creates per second and pushes p99 past 10 seconds. The same effect shows up at
the API level — raising `DB_POOL_WEB` from 4 to 40 took `POST` p99 at 30
concurrent clients from 767 ms to 105 ms.

*Delta, two parts:*

1. **Do not hold the transaction across the emberd call.** Take the row lock,
   check and advance state, commit; make the host call with no connection held;
   then reopen a short transaction to record the result. The design already
   carries a `generation` column and a reconciling `Prog::Ember::Nexus` for
   exactly the failure this opens up, so the pieces are there. This turns
   throughput from pool-bound into thread-bound.
2. **Size `db_pool_web` to the thread count.** Four connections for fifteen
   threads is a poor default for any synchronous path, and silently so, because
   the median stays clean while the tail collapses.

**A related hazard for the gateway.** Locking one row serialises by design, and
that is what the design wants for concurrent resumes of the *same* ember. But
it is unforgiving: 20 concurrent resumes of one paused ember, at 500 ms each,
queue to a p50 of 10 s and a p99 of 19 s. That is precisely the shape of a
thundering herd against one ember — an agent opening a connection pool, or a
client retrying — and the gateway holds each client for up to 15 s (8.2). The
resume path needs to collapse duplicate waiters onto one in-flight resume
rather than queueing them behind the row lock.

**Method note.** The first version of this measurement reported 43 ms for the
emberd hop against a 0.79 ms network RTT. That was the WEBrick-based stub
writing its status line, headers and body as separate small writes — the same
Nagle/delayed-ACK stall as 2.3, reproduced by accident. `emberd_stub.rb` is
now a hand-rolled server that sets `TCP_NODELAY` and writes one buffer, which
is what took the hop from 43 ms to 0.5 ms. Worth knowing before emberd is
written: this failure mode has now shown up twice in one system.

### 2.12 The gateway should stay a compiled binary; Ruby is the wrong tool here

Section 8.2 specifies a Go or Rust gateway. The question is worth asking, since
everything else in the control plane is Ruby — but the answer is clear, and for
a specific structural reason rather than general performance folklore.

**The trust model forces double TLS.** The gateway cannot hand the wildcard
certificate's key to an untrusted guest, so it terminates the client's TLS and
opens a second TLS session to the ember with a per-ember certificate (8.3).
Every tenant byte is therefore decrypted and re-encrypted in the gateway. That
makes it the one component in the system whose CPU cost scales with tenant
traffic, rather than with the number of operations.

Two minimal gateways with identical behaviour — terminate client TLS, dial TLS
upstream, splice both ways — on the 32-thread test host, against a Go upstream
over loopback (`scripts/postgres_ember_spikes/gwbench/`):

| | Go | Ruby (thread per direction) | |
|---|---|---|---|
| Small round trips, 50 conns | 0.21 ms p50, 218k req/s | 1.72 ms p50, 28k req/s | **8x** |
| Small round trips, 200 conns | 0.50 ms p50, 377k req/s | 7.63 ms p50, 25k req/s | **15x** |
| Bulk, 20 conns | 8,829 MB/s | 473 MB/s | **19x** |
| Bulk, 100 conns | 9,602 MB/s, 9.8 ms p50 | 745 MB/s, 128 ms p50 | **13x** |
| CPU actually used | up to 1,500 % | **pinned at ~117 %** | |
| RSS, 500 idle connections | 75 MB (0.15 MB/conn) | 1,470 MB (**3.0 MB/conn**) | **20x** |

The interesting column is CPU. Ruby never exceeds about 1.2 cores no matter how
much load is offered: bulk crypto runs under the GVL, so a single process is a
one-core gateway on a 32-core machine. Per core Ruby is actually competitive
(~24k round trips per core against Go's ~18k) — it simply cannot use a second
core. Go reached 377k req/s across 13 cores on the same box.

The memory figure matters just as much, and for the opposite reason. An ember
gateway holds mostly *idle* PostgreSQL sessions, and at 3 MB per connection a
replica holding 2,000 of them needs 6 GB purely for connection state, against
300 MB for Go.

**What would close the gap, and why it does not help.** Two threads per
connection is wasteful; fibers with an event loop would cut the memory cost to
roughly nothing. But fibers add no parallelism in MRI, so the ~1.2 core ceiling
would remain, and lifting that needs `SO_REUSEPORT` across N processes. At that
point the route cache, the per-ember connection caps and the batched activity
accounting — all three of which section 8.2 wants per replica — fragment across
processes and need shared state. The end state is an evented, multi-process,
shared-state Ruby program, which is precisely where Ruby's readability
advantage disappears.

**And the deployment argument cuts the same way.** Section 8.1 models the
gateway on `Prog::Ai::InferenceRouterReplicaNexus`, which already deploys a
*compiled* binary: fetched from a GitHub release with `fetch`, untarred, run
under a hardened systemd unit with a pushed JSON config. Shipping a Go or Rust
binary is an existing, solved path in this repo, not a new burden.

*Delta:* none — section 8.2 was right. Keep the data plane compiled. Note the
corollary though: the gateway's *interesting* logic (SNI routing, resume on
connect, collapsing duplicate waiters per 2.11, activity batching) is
low-frequency control logic where the language hardly matters. Keep that layer
thin and well tested, and resist the temptation to move policy into it.

Caveat: this is loopback against a synthetic upstream, so it stresses the
crypto and splice path harder than a real workload of mostly idle sessions.
That flatters neither implementation in particular — and the idle-memory
measurement, which is the one that most resembles real usage, is where Ruby
does worst.

### 2.13 A TLS-terminating gateway breaks SCRAM channel binding (blocking)

Running the gateway in front of a real ember works, and the interesting path
works well. Bringing up an ember whose PostgreSQL terminates TLS with a
per-ember certificate, standing in for the control plane's internal API, and
driving it with psql (`s13_gateway_e2e.rb`):

| | Measured |
|---|---|
| Query through the gateway, ember already running | 37 ms |
| **Connect to a paused ember: resume on connect, then read the data back** | **515 ms** |
| Activity reported to the control plane | 5,240 bytes, correct ember |
| Data written before the pause, read after the resume | intact |

But the default libpq connection fails:

```
psql: error: connection to server at "ember1.ember.test", port 6432 failed:
      FATAL:  SCRAM channel binding check failed
```

**Why.** `channel_binding=prefer` is libpq's default, so the client picks
`SCRAM-SHA-256-PLUS` whenever the server advertises it, and PostgreSQL
advertises it whenever `ssl` is on. Channel binding of type
`tls-server-end-point` hashes *the server's certificate*. The client hashes the
gateway's wildcard certificate; the ember verifies against its own
per-ember certificate. They cannot match, by construction, because the
gateway terminates one TLS session and opens another. Every out-of-the-box
`psql` and libpq connection therefore fails. The measurements above were taken
with `channel_binding=disable`.

This is not a bug in the gateway. It is the design's own security property —
two TLS sessions because the wildcard key cannot be given to an untrusted
guest (8.3) — colliding with a protocol feature whose purpose is to detect
exactly that shape of interception.

**The obvious fix does not work.** The tempting move is for the gateway to
strip `SCRAM-SHA-256-PLUS` from the mechanism list in the server's
`AuthenticationSASL` message, so the client falls back to plain SCRAM. It
fails: a client that supports channel binding but is offered no `-PLUS`
mechanism sends the gs2 flag `y`, and PostgreSQL's `read_client_first_message`
raises this same error when it sees `y` while `ssl_in_use` is true, precisely
to catch downgrade attacks. The gateway cannot rewrite the gs2 flag either,
because it is covered by the client's SCRAM proof. (Reasoned from the
PostgreSQL source rather than measured; worth confirming before relying on it.)

**Options, in the order I would consider them.**

1. **Encrypt the gateway-to-ember hop below PostgreSQL** and run the
   ember's PostgreSQL without `ssl`. With no SSL in the ember, no `-PLUS`
   is advertised, the client uses plain SCRAM end to end, and default libpq
   works. The hop stays encrypted, which is what 8.3 actually wants; it just
   moves from the PostgreSQL protocol to the network. The tunnel mesh is
   gateway replicas times ember hosts — small and static, nothing like the
   VM-to-VM mesh the design avoided. This keeps per-ember authentication of
   the *host* if the tunnel is per host, but loses the per-ember certificate
   binding, so section 8.3's argument needs revisiting.
2. **Let the gateway terminate SCRAM**, authenticate the client itself, and
   open its own authenticated session to the ember. Channel binding then
   works properly on the client hop, because the gateway both terminates TLS
   and speaks SCRAM. This is what pgbouncer and Neon's proxy do. The cost is
   that the gateway becomes credential-bearing, which is a real change to the
   trust model in section 9 and needs its own review.
3. **Plaintext between gateway and ember.** Simplest, works immediately,
   gives up 8.3 entirely.
4. **Document `channel_binding=disable`.** Not viable: libpq's default fails,
   so every connection breaks until the user changes it.

**Decided: option 1.** The gateway now connects to the ember in plaintext by
default, with the hop to be encrypted below PostgreSQL, and a route can opt
back into a second TLS session with `"upstream_tls": true` and a `cert_cn`.
Both transports are tested and verified end to end against a real ember:

| | default libpq | query | resume on connect |
|---|---|---|---|
| plaintext hop (chosen) | **works** | 25 ms | 523 ms |
| second TLS session (opt-in) | fails, as above | 30 ms | 524 ms |

Two things followed from choosing this way round. The reversibility is
asymmetric: adding gateway-terminated SCRAM later is additive, rolls out per
ember, and only ever *gains* a client channel binding, whereas removing it
would break clients configured `channel_binding=require` and would mean
rotating every ember password. And keeping the upstream-TLS path rather than
deleting it costs 78 lines out of ~1,100, so the transport half of that future
switch is already done.

*Delta:* section 4.1 drops `ssl` from the ember's PostgreSQL configuration,
section 5.3 step 6 and section 8.3 lose the per-ember certificate, and
section 8 gains a tunnel between the gateway replicas and the ember hosts.
**That tunnel is not built yet** — it is the remaining work for this decision,
and until it exists the hop is unencrypted.

### 2.14 The guest needs no agent

Every job the vsock agent did has an agentless equivalent, and removing it
costs nothing measurable. The data disk's hot-plug drives the guest through
udev and systemd: the restore hook (a 0.6 ms static binary that reseeds the
CRNG from `/dev/hwrng` and sets the clock from `ptp_kvm`), then fsck, the
`/data` mount and PostgreSQL. The host waits with a PQping and configures
PostgreSQL over SQL from the slot's tap address, which the PGDATA image's
`pg_hba` trusts for the postgres role; nothing outside the slot's namespace
can originate from it, because the slot's nftables drops a guest's packets
from any address but its own and admits new connections only from the
gateways and the host's end of the veth. Pause is the ACPI power button.

`s14_agentless.rb`, same host, same template size, against `s2_lifecycle.rb`
on the same image with the agent layered back in (`agent_image.sh`):

| | agent | agentless |
|---|---|---|
| Create | 527 ms | 451 ms |
| Resume | 452 ms | 363–494 ms |
| Pause | 225 ms | 209–265 ms |
| Clock after resume | set by the agent | within the ±10 ms of the measurement |

Through emberd itself, driven over its HTTPS API: create 911 ms, resume
695–703 ms, pause 227–333 ms, password change 25 ms, claim a blank 137 ms.
The extra ~400 ms against the harness is emberd starting the volume and the
VM as systemd units, unchanged by this.

Three things came out of measurement:

* **Pause needs the image's help.** A plain power-off took ~700 ms, stopping
  every unit in turn. `/data` is taken out of `local-fs.target`, so it
  unmounts as soon as PostgreSQL stops, and `ember-fast-off.service`, ordered
  after both, syncs and powers off without waiting for the rest.
* **Hot-plug to PostgreSQL is ~260 ms**, of which ~100 ms is udev processing
  the new disk; the agent avoided it by reading the serial from sysfs. Masking
  the storage stack's rules (md, lvm, multipath, snapd's auto-import, ...)
  and units a power-off stops one by one is in the image; the agent image
  gained from it as well, which is why its resume here is faster than in 1.
* **Randomness.** With the hook, two clones' kernel UUIDs and
  `gen_random_uuid()` differ. So they did without it, unlike 2.5: the guest's
  kernel clock jumps on restore, which triggers the kernel's own reseed from
  the timing noise gathered since. That is weak entropy and not something to
  rely on, and the hook costs 0.6 ms, so it stays. (The negative control was a
  copy of the image with a drop-in running the hook as `--no-reseed`.)

A tenant, being superuser, can edit `pg_hba.conf` or drop the role and lock
emberd out of their own ember's configuration. That was not possible with a
root agent, and it costs the tenant only their own password resets.

## 3. Answers to section 14's open decisions, where the spikes have one

1. **Memory per ember: 384 MiB.** Measured flat restore latency across
   512/384/256 MiB and a working 2M-row workload at 384 but not at 256 (2.8).
2. **Superuser for the tenant:** untested here, but nothing in the isolation
   results argues against it (2.6).
3. **Extension list:** not exercised; the spike image carries only contrib.
4. **Egress policy:** the "no egress" rule is enforced and verified (2.6).
5. **Local retention after pause:** not exercised, but note that archive
   restore measured *faster* than cross-host restore (2.3, 2.4), which weakens
   the argument for long local retention.
6. **Resuming expired embers from the archive:** the archive round trip is
   byte-exact (2.4), so this is a policy question, not a technical one.
7. **Naming:** untouched.

Two decisions the spikes add to the list:

8. **Keep the ext4 journal on the PGDATA image** (2.7). Currently specified
   away in 4.1.
9. **Decide the host userfaultfd policy** (2.2), because `ondemand` restore
   depends on it and degrades silently to `copy` speeds without it.

---

## 3.1 Revised time budget (replaces section 10)

Milliseconds, p50, measured, `ondemand` restore, 512 MiB template, with the
ubiblk changes from 2.3 applied. Absolute values on this host moved by up to
20 % across the session; the within-run comparisons are the reliable part.

| Phase | Claim blank | Cold create | Resume local | Resume remote | Resume archive |
|---|---|---|---|---|---|
| Volume backend start | – | 16 | 17 | 20 (patched; 1,343 stock) | 32 |
| cloud-hypervisor restore + resume | – | 26 | 26 | 26 | 26 |
| Agent reachable + `post_restore` | – | 44 | 45 | 45 | 45 |
| Hot-plug data disk | – | 1 | 1 | 1 | 1 |
| Agent `attach` (device + mount) | – | 90 | 90 | ~90 | 927 |
| PostgreSQL start | – | 285 | 282 | ~300 | ~830 |
| Password / database / TLS | 34 | (in pg_start) | – | – | – |
| First query | – | 26 | 26 | 27 | 29 |
| **Total** | **34** | **525** | **519** | **555** | **1,548** |

Control-plane, gateway and network hops are not included; they were out of
scope for these spikes.

---

## 4. Spike status against section 12

| Spike | Status | Pass condition |
|---|---|---|
| S1 restore path | done | **pass** — p50 62 ms (`ondemand`) / 161 ms (`copy`), hot-plug 0.8 ms, `pg_start` 300 ms, concurrent clones proven at 103 |
| S2 volume lifecycle | done | **pass** — same-host, cross-host and archive paths all verified byte-for-byte; cross-host first query was 1,957 ms against stock ubiblk and is 657 ms with the change in 2.3 |
| S3 clone safety | done | **pass** — reseed necessary and sufficient, clock within 26 ms, isolation holds |
| S4 template portability | **not run** | needs a second host model; only one machine was available |
| S5 density | done | **pass** — p95 511 ms at 100 % occupancy; memory cost higher than planned |

Three spikes beyond section 12, prompted by what the others turned up:

| Spike | Question | Result |
|---|---|---|
| `s7_template_size.rb` | decision 1: is 384 MiB enough? | yes; 256 MiB is not (2.8) |
| `s8_privilege.rb` | does any of this work as a per-slot unix user? | yes, and `ondemand` needs a host userfaultfd policy (2.2) |
| `s9_crash_safety.rb` | does an ember survive an unclean pause? | only with a journalled PGDATA filesystem (2.7) |
| `s10_deferred_autofetch.rb` | can catch-up be deferred until the ember is serving? | yes, with the `start_autofetch` RPC (2.3) |
| `s11_control_plane_latency.rb` | does the synchronous API path fit its budget? | yes, ~11 ms, but the DB pool is the constraint (2.11) |
| `s12_sync_path_components.rb` | what do the emberd hop and the held transaction cost? | 0.5 ms and the whole host call, respectively (2.11) |
| `gwbench/` | should the gateway be Go or Ruby? | Go: Ruby is GVL-capped at ~1.2 cores and 3 MB per connection (2.12) |
| `s13_gateway_e2e.rb` | does the gateway work against a real ember? | yes, resume on connect in 515 ms, but SCRAM channel binding breaks (2.13) |
| `s14_agentless.rb` | can the guest do without an agent? | yes, at no cost (2.14) |

S4 is the remaining gap. It needs at least two different CPU models in one
location to determine how coarse `cpu_signature` can be; this host is a single
Ryzen 9 7950X3D.

## 5. Running the spikes

```sh
scripts/postgres_ember_spikes/sync.sh <host>   # push to an ember host
ssh root@<host> 'bash /root/ember_spikes/prep_host.sh'
# The production images, from postgres-vm-images' ember build, which writes
# cell-root-18.raw and cell-pgdata-18.raw -- the names the spikes expect:
#   git clone https://github.com/ubicloud/postgres-vm-images
#   OUT=/var/storage/ember/images bash postgres-vm-images/cell/build.sh
ssh root@<host> 'bash /root/ember_spikes/agent_image.sh' # the agent, for s1-s13
ssh root@<host> 'cd /root/ember_spikes && ruby build_template.rb t512 512'
# The ubiblk changes in 2.3 are on ubiblk's start-autofetch-rpc branch (two
# of them already merged into main); build it on the host and pick it per run
# with UBIBLK_DIR, which lib/ember.rb reads (the default is whichever
# /opt/vhost-block-backend/v* sorts last):
#   git clone -b start-autofetch-rpc https://github.com/ubicloud/ubiblk
#   cd ubiblk && cargo build --release
#   install -D -t /opt/vhost-block-backend/start-autofetch-rpc target/release/{vhost-backend,remote-stripe-server,init-metadata,archive}
#   export UBIBLK_DIR=/opt/vhost-block-backend/start-autofetch-rpc
ssh root@<host> 'cd /root/ember_spikes && ruby s1_restore.rb t512 20'
#                                           ruby s2_lifecycle.rb t512 3 ondemand
#                                           ruby s3_transfer.rb t512 200
#                                           ruby s4_clone_safety.rb t512 3
#                                           ruby s5_archive.rb t512 100
#                                           ruby s6_density.rb 100
#                                           ruby s7_template_size.rb 512 384 256
#                                           ruby s8_privilege.rb t512
#                                           ruby s9_crash_safety.rb t512 3
#                                           ruby s10_deferred_autofetch.rb t512 200
# probes: probe_remote_start.rb, probe_remote_connections.rb, probe_nagle.rb
# s14, against the production image with no agent in it:
#   ruby build_template_agentless.rb a512 /var/storage/ember/images/cell-root-18.raw
#   ruby s14_agentless.rb lifecycle a512 3
#   ruby s14_agentless.rb clones a512
```

The control-plane spikes run on the machine hosting Clover, not on the ember
host:

```sh
RACK_ENV=production DB_POOL_WEB=40 bundle exec puma -C puma_config.rb
ssh root@<host> 'ruby /root/ember_spikes/emberd_stub.rb 8452'
MODE=production TOKEN=pat-... PROJECT=pj... \
  ruby scripts/postgres_ember_spikes/s11_control_plane_latency.rb
EMBERD=https://<host>:8452 \
  bundle exec ruby scripts/postgres_ember_spikes/s12_sync_path_components.rb
ssh root@<host> 'bash /root/ember_spikes/cleanup.sh --volumes'
```

`s5_archive.rb` needs an S3 endpoint; the spike used a MinIO instance on the
host itself (the release the repo already pins in `rhizome/minio/lib/minio_setup.rb`).
