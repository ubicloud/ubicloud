# Postgres Ember: implementation status

Where the Postgres Ember design stands in this branch. The spikes that
preceded it, and the measurements that shaped several of these decisions, are
in `scripts/postgres_ember_spikes/FINDINGS.md`.

## Built, with tests

Everything here is committed, lint-clean, and at 100% line and branch coverage
where the repo enforces it.

**Control plane — data model.** `detachable_volume` plus six ember tables
(`ember`, `postgres_ember`, `ember_template`, `ember_template_host`, `ember_pool`,
`postgres_gateway`, `postgres_gateway_replica`, `postgres_ember_rate_limit`)
with their models. An ember is generic -- a micro-VM in a slot with a volume and
an idle lifetime -- and `postgres_ember` is the 1:1 row that makes one a
database, in the way `PostgresServer` wraps a `Vm`. There is no ember host
table either: a host that runs embers is a `vm_host` brought up with
`accepts_embers`, and runs nothing else. No per-ember certificate columns: the hop to the ember
is encrypted below PostgreSQL (see 2.13 in the findings).

**Control plane — synchronous path.** `VmHost.ember_candidates_for`
placement, and `EmberOperations` create/resume/pause, which run `host/bin/ember` on
the host through its `Sshable`, with `PostgresEmberOperations` supplying the
Postgres template and credentials. The operations commit
their state change before calling the host and reopen a short transaction
afterwards, because holding a pooled connection across the call caps the web
process at pool-size-over-call-duration.

**Control plane — progs.** `Prog::Ember::Nexus` (idle detection, expiry,
reconciliation, destroy), `Prog::Vm::HostNexus` (bring-up without hugepages, ember
setup, the CPU signature, drain), `Prog::Ember::Pool` (the location's warm pool),
`Prog::Ember::TemplateNexus` (build on every host, retire),
`Prog::Storage::DetachableVolumeNexus` (assemble, catch-up, destroy).
Detachable volumes stand on their own; embers start theirs inside `host/bin/ember`,
in the same call as the VM.

There is no separate kind of ember host: an ember host is a `VmHost` brought
up with `accepts_embers: true`, which runs embers and nothing else, and its own
strand runs the ember setup. It has no hugepages, which keeps VMs off it, and
its memory is divided into slots; see `doc/postgres_ember_deploy.md`.

**API.** The project-scoped REST API with its OpenAPI schema, serializer,
`PostgresEmber:*` action types and a `PostgresEmberCount` quota; the anonymous surface
(`POST /ember` with no account, per-address limiting, a token that both
manages and claims the ember); and the gateways' internal API on its own
host-routing scope.

**Web UI.** List, create, and a detail page with the connection string,
pause/resume, password reset and delete, behind the same `PostgresEmber:*`
permissions as the API.

**Images.** Built and published by the ember workflow in `postgres-vm-images`,
agentless, with the corrections from the findings applied: journalled PGDATA,
the data disk found by serial, PQping readiness, quiesced snapshots, the reseed
ordered before anything that reads the disk. They are ordinary boot images,
downloaded when an operator lists them in a host's `default_boot_images`, and
a template is built from the ones the operator names. Verified on the spike host with the published 20260925.1.0 images,
fetched by `host/bin/download-boot-image` and driven through `host/bin/ember`:
create, three pause/resume cycles with the data intact, a blank and its claim,
a password change, and two clones with distinct randomness.

**Gateway.** A standalone Go module in its own repository,
[ubicloud/postgres-gateway](https://github.com/ubicloud/postgres-gateway):
PostgreSQL startup protocol, SNI routing, route
caching, resume on connect with duplicate waiters collapsed onto one call,
connection caps, activity accounting, and an admin surface. Verified end to end
against a real ember on real hardware: 25 ms for a query, 523 ms to connect to a
paused ember including the resume.

## Built, without tests

Written to the same standard but not covered by specs, at the operator's
instruction. These are the files a reviewer should read most closely, and the
work to finish before this branch is mergeable is their spec suites.

**The host side, `rhizome/host/`.** `host/bin/ember`, one command per operation
with no daemon behind it: `setup`, the slot namespace builder and
nftables template, restore, hot-plug, pause, the blank pool, template builds
(run as a unit of their own), and listing what each slot holds. The slot state lives in a file
changed only under a lock, so two commands never take the same slot. None of
it depends on what runs in an ember. The Postgres part,
`GuestPostgresManager` in `rhizome/host/lib/`, waits for the server and
configures it; `EmberManager` finds it by the workload's name, which is where
a second workload would plug in. The mechanics were
validated first in `scripts/postgres_ember_spikes/lib/ember.rb`, which measured
every number in the findings, so this was a port rather than a design
exercise.

**The gateway-to-host tunnel.** `lib/ember_tunnel.rb` and
`rhizome/host/bin/setup-ember-tunnel`: an IPsec mesh of a location's gateway
replicas against its ember hosts, the same IPsec private subnets use -- ESP in
tunnel mode, keys from the control plane rotated daily in three steps, set up
with `ip xfrm`. The gateway end is terminated in the gateway VM's namespace on
its host, as a private subnet's tunnels are, so nothing runs in the VM for
it. Choosing option 1 in findings 2.13 moved the encryption of that hop out of
PostgreSQL's TLS and into the network, and this is where it went. Verified on
the spike host with namespaces standing in for both ends: traffic is ESP on
the wire, a cleartext packet claiming a gateway's prefix is dropped, and three
key rotations under a 10 ms ping lost nothing.

**Gateway deployment progs.** `Prog::Postgres::GatewayNexus` and
`GatewayReplicaNexus`: the load balancer, the wildcard certificate, replica
VMs, the binary fetched by tag into a hardened unit, and the source set pushed
to ember hosts.

**CLI and SDK.** `ubi pg ember` (`cli-commands/pg/ember/`) and `Ubicloud::PostgresEmber` in the
Ruby SDK. The CLI golden files are updated, so the help output is checked;
the command bodies are not.

## Not built

**MCP tools.** There is no MCP surface in this repository to add them to.

**S4, template portability.** The one section 12 spike never run: it needs two
CPU models in one location, and the spike host was a single Ryzen 9 7950X3D.
It decides whether `cpu_signature` can be coarser than per-model, which
changes how many templates a location has to build.

## Known-bad, deliberately

**The web process has to be allowed SSH.** Creating, resuming and pausing a
ember happen inside the API request, and they run `host/bin/ember` over the host's
SSH session, so the web process runs with `ALLOW_WEB_SSH=true` against the rule
that it never touches SSH. The way out, left for when this matures, is a
process type of its own that holds warm SSH sessions to the ember hosts: the
web process records a request (ids only, no secrets) and NOTIFYs, and that
process builds the payload from the database, runs host/bin/ember and NOTIFYs back.
That keeps SSH out of the web process at about a millisecond each way, at
the cost of one more thing to deploy.

**A pause inside the gateway's route TTL costs a failed dial.** The gateway's
admin port is bound to localhost by design, so the control plane cannot
invalidate the cache when it pauses an ember. The gateway re-resolves a route
that will not dial, so the connection succeeds, but it pays the dial timeout
first. Either the admin port has to be reachable from the control plane, or
the route response needs a version the gateway can check cheaply.

## Verified on real hardware

The whole path was run end to end on one Hetzner AX102 (Ryzen 9 7950X3D, 16 cores, 128 GB) on
22 Sept 2026: host bring-up, template build, create, connect, pause, resume.
Nine bugs came out of it, all in code that had never executed; they are in the
commit "Make the ember path work against real hardware".

| | |
|---|---|
| create a database, cold | 1.1 s |
| query through the gateway | 35 ms |
| pause | 353 ms |
| connect to a paused ember, including resume | 899 ms |
| claim a warm blank (disabled, see above) | 186 ms |

Data written before a pause was read back after the resume.

## Deviations from the design worth reviewing

1. **The hop to the ember is plaintext by default**, with TLS opt-in per
   route, and IPsec underneath. A TLS-terminating gateway cannot satisfy
   SCRAM channel binding, so with `ssl` on in the ember every default libpq
   connection failed.
2. **Detached volumes are never archived.** The design uploads a detached
   volume to the location's object store and then drops the host's copy.
   Here a volume stays on its host until it is destroyed, which costs the
   host's disk and is not durable against losing the host. An ember resumed
   elsewhere is meant to fetch its stripes from the host holding them, but
   nothing sets that up yet, so a resume only works on the volume's own
   host.
3. **An ember's name is not its ubid.** The repo rejects ubid-shaped names so
   that name and id stay unambiguous in URLs; the name is derived from the
   ubid instead.
4. **Templates default to 384 MiB**, not 512 MiB: measured flat restore
   latency across sizes, and 256 MiB loses the postmaster during an index
   build.
5. **Embers run on ordinary VM hosts.** The design gives them a pool of their
   own. The only thing that actually required it was addressing -- slot
   addresses are a /79 out of the same /64 the VM allocator picks from -- and
   excluding that one block is enough. Keeping embers off hosts serving
   dedicated databases stays available as a placement decision.
6. **There is no host agent.** The design has a daemon on each host with an
   authenticated HTTPS API. Here every operation is a `host/bin/ember` command run
   over the SSH session the control plane already holds, so there is no
   daemon to keep running, and no port, certificate or secret. It costs about
   120 ms a call, mostly starting Ruby and loading the code, against 0.5 ms
   for kept-alive HTTPS: a warm claim measured 241 ms, a resume 905 ms and a
   pause 362 ms. Getting the SSH part that low took TCP_NODELAY on cached
   sessions, without which a command on a warm session measured 46 ms.
7. **Templates are built on every host**, not built once and distributed
   through the object store. A build is one cold boot, about 25 s, and a copy
   would need a channel between hosts or object-store credentials on each.
8. **The anonymous management token is the claim token.** The design has a
   separate management token; one token is fewer secrets to hand out and
   claiming an ember clears it, which is exactly when anonymous access
   should end. The claim keeps the superuser password, so the connection
   string does not change. The cost is that the token is presented on every management
   call rather than once.
