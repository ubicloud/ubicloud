# Deploying Postgres Ember on a new host

What follows was derived from bringing the whole path up on one bare-metal
host and one gateway VM. Every step is something that was actually run; where
this environment could not exercise something, it says so.

Ordering matters in one place only: a template can only be built once a
ember host exists, and an ember is only placeable once a template is ready
on a host whose CPU matches.

## 0. What you need first

* A control plane with the migrations applied and `respirate` running.
* A bare-metal host for embers alone. An ember host is a `VmHost` brought up
  with `accepts_embers: true` (step 3) and runs nothing else; a host runs
  embers or VMs, never both. Its ubiblk (`vhost_block_backend_version`) has to
  be v0.5.1 or newer.
* A project to own the fleet's VMs, the warm pool's volumes and anonymous
  embers.

## Memory

An ember host has no hugepages. Embers take ordinary memory, and a host with
no hugepages is one the VM allocator never places a VM on, which is what keeps
VMs off it. Its memory is divided into slots when it is brought up: what is
left after 8 GiB for the host itself, at `EMBER_DEFAULT_MEMORY_MIB` plus about
30 MiB for each ember's cloud-hypervisor and ubiblk processes. A guest's memory
is all resident once it has run, so a free slot always has memory behind it
and slots are the only capacity the control plane tracks.

## 1. Configuration

```
EMBER_SERVICE_PROJECT_ID    the project above
POSTGRES_GATEWAY_TOKEN_SECRET  shared with the gateways; they mint HS256 with it
POSTGRES_EMBER_INTERNAL_API_URL      where a gateway reaches the control plane
POSTGRES_GATEWAY_HOSTNAME_SUFFIX  the wildcard name, pgc.ubicloud.app by default
```

The web process also needs `ALLOW_WEB_SSH=true`. Creating, resuming and
pausing an ember happen inside the API request, and they run `host/bin/ember` on the
host over SSH, which the web process otherwise refuses outright. See "Known-bad" in
`postgres_ember_status.md`.

Optional, and worth knowing about:

```
POSTGRES_GATEWAY_ADDRESS       set when there is no wildcard DNS; see step 6
POSTGRES_GATEWAY_BINARY_URL    a tarball to install instead of a GitHub release
EMBER_POOL_TARGET                    warm blanks per host, default 4
POSTGRES_EMBER_VOLUME_SIZE_GIB       default 2
POSTGRES_EMBER_IDLE_TIMEOUT_SECONDS  default 300
POSTGRES_EMBER_UNCLAIMED_TTL_SECONDS default 259200
```

`POSTGRES_EMBER_DEFAULT_MEMORY_MIB` defaults to 384 rather than the design's 512.
That is measured: restore latency is flat across template sizes, and 256 MiB
loses the postmaster during an index build.

## 2. The images

An ember runs from two images, both built and published by the ember workflow in
`postgres-vm-images`:

* `postgres-cell-root-18` -- the read-only root every ember VM boots from
* `postgres-cell-pgdata-18` -- an initialised PGDATA a fresh volume reads
  through to

They are ordinary boot images. Put both in the host's `default_boot_images`
when it is set up, or download them onto a host you already have:

```ruby
%w[postgres-cell-root-18 postgres-cell-pgdata-18].each { vm_host.download_boot_image(it) }
```

`DownloadBootImage` leaves them in `/var/storage/images/<name>-<version>.raw`,
where the host reads them, at the latest version in
`Prog::DownloadBootImage::BOOT_IMAGE_SHA256`. A host needs both before it
builds a template. A new image version is a new entry in that table, and a
new template built from it.

Nothing in the guest listens for the host. Hot-plugging the data disk is what
starts PostgreSQL: udev pulls in `cell-postgres.service`, which waits for the
restore hook (reseed the CRNG from virtio-rng, set the clock from ptp_kvm),
fsck and the `/data` mount. The host configures PostgreSQL over SQL from the
slot's tap address, which the PGDATA image's `pg_hba` trusts for the postgres
role, and pauses an ember with the ACPI power button, on which the image stops
PostgreSQL, unmounts `/data` and powers off.

The PGDATA image must be journalled. A non-journalled one does not survive the
first unclean kill.

## 3. Bring the host up for embers

```ruby
Prog::Vm::HostNexus.assemble(host_address, accepts_embers: true, vhost_block_backend_version: "v0.5.1",
  default_boot_images: %w[postgres-cell-root-18 postgres-cell-pgdata-18], provider_name:, server_identifier:)
```

This is the ordinary host bring-up with the VM-only parts left out: no
hugepages, and after the reboot, instead of starting slices and VMs, the host
installs what the guests need, prepares the slots and learns the CPU
signature. Its slot addresses are the first /79 of its /64 that does not hold
its own address. The location's gateway then peers with it. Nothing can be
placed on it until the signature is known, because x86 restore checks CPUID
against the snapshot's host.

Watch `vm_host.strand.label` until it is at `wait` and `vm_host.reload.cpu_signature`
is set. The slots are set up again after every reboot, since namespaces and
taps do not survive one. Drain a host with `vm_host.incr_drain_embers`: it
goes to `draining` and its running embers are paused; setting it back to
`accepting` returns it.

TEMPORARY: until ubiblk releases the start_autofetch RPC, build the ubiblk
embers run on the host and register it. It takes several minutes and is done
once:

```sh
sudo host/bin/build-ember-ubiblk
```

```ruby
VhostBlockBackend.create(vm_host_id: vm_host.id, version: "v0.5.99", allocation_weight: 0)
```

The control plane runs embers on the newest ubiblk a host has at or above
v0.5.1, so this build, installed as v0.5.99, takes over from the release the
bring-up installed. A weight of 0 keeps VMs from ever picking it.

## 4. Build a template

```ruby
Prog::Ember::TemplateNexus.assemble(
  location_id:, cpu_signature: vm_host.ember.cpu_signature,
  workload: "postgres", version: "18",
  root_image: "postgres-cell-root-18-20260925.1.0",
  data_image: "postgres-cell-pgdata-18-20260925.1.0",
)
```

`root_image:` and `data_image:` name the images step 2 downloaded, the way
the host keeps them: `<name>-<version>`.

The build cold-boots the root image in a slot outside the ember range, waits
for the guest to say on its serial port that boot has settled, and snapshots. The quiescing is not optional: a
snapshot taken while systemd is still starting units makes every restored
clone replay the tail of boot, at about 500 ms each with no other symptom.

Wait for `EmberTemplate.first.state == "ready"`. A minute or so.

Every host whose signature matches builds its own copy. The template is ready
once the first has, and a host added later builds one when it appears.

## 5. Start the location's warm pool

```ruby
Prog::Ember::Pool.assemble(location_id, workload: "postgres")
```

One pool per location, holding blanks -- embers already restored against a
fresh volume and waiting to be claimed. A claim is a password change rather
than a restore, which is the difference between 186 ms and 1.1 s. The pool
spreads its blanks across the location's accepting ember hosts and refills one
at a time, so it absorbs bursts rather than creating them.

Nothing breaks without it; creates just always take the cold path. Raise or
lower `postgres_ember_pool.target` to trade idle memory for create latency.

## 6. Bring up the gateway fleet

```ruby
Prog::Postgres::GatewayNexus.assemble(location_id)
```

This creates the fleet's private subnet, its load balancer on 5432 as pure TCP
passthrough, and its replica VMs. Each replica joins the mesh, installs the
gateway, and joins the load balancer once its health endpoint answers.

Two things it needs that it cannot do for you:

* **The release.** Replicas fetch the x86_64 tarball from the
  [ubicloud/postgres-gateway](https://github.com/ubicloud/postgres-gateway)
  release named by `postgres_gateway_release_tag` (`postgres-gateway/v0.1.0`
  by default). For a development or air-gapped deployment, set
  `POSTGRES_GATEWAY_BINARY_URL` to your own tarball instead.
* **The certificate.** The replica waits, without erroring, until the load
  balancer has an active certificate for `*.<hostname suffix>`. That is
  ACME's job and needs the DNS zone; this was not exercised here, and a
  self-signed certificate was substituted to prove everything downstream of
  it.

## 7. Point clients at it

Normally: one wildcard DNS record, `*.pgc.ubicloud.app`, at the load
balancer. The gateway reads the ember id out of the SNI name, so no DNS change
ever happens per ember. There is no location in the name, because embers run
in a single location; a second one would need per-ember records or a gateway
that forwards between locations.

The wildcard certificate lives only on the gateway replicas. An ember has no
TLS of its own -- the hop from the gateway runs over the IPsec mesh -- and
nothing secret is put in its guest, because the tenant is superuser there
and can read any file the postgres user can.

SNI is the only way a client names an ember: the gateway has no fallback in
the startup packet, so a client that does not send SNI (libpq before 14, or
anything connecting without TLS) is refused with an error saying so. Without
a fallback to strip, the same connection string also works against a
dedicated server once an ember is upgraded to one.

Where there is no wildcard record -- self-hosted, or development -- set
`POSTGRES_GATEWAY_ADDRESS` to the gateway's IP address instead. Connection
strings then carry it as `hostaddr`, so libpq dials the gateway directly and
still sends the ember's name, and the API, CLI and web UI all report the
connection string that actually works.

## 8. Check it

```ruby
ember = PostgresEmberOperations.create(project:, location:)
puts ember.connection_string(Config.postgres_gateway_hostname_suffix)
```

Then connect with exactly that string. On the hardware this was developed against (a
Hetzner AX102: Ryzen 9 7950X3D, 16 cores, 128 GB): about 1.1 s to create cold, 186 ms from the warm pool, 35 ms for a
query through the gateway, 353 ms to pause, and 950 ms to connect to a paused
ember including the resume.

## Operating it afterwards

* **Draining a host's embers** -- `vm_host.incr_drain_embers` stops placement and pauses
  everything running on it. Each tenant's next connection resumes their
  ember wherever there is room. Re-enabling is a deliberate act:
  `vm_host.update(allocation_state: "accepting")`.
* **Retiring a template** -- `postgres_ember_template.incr_destroy` waits for the
  embers still running it.
* **Detached volumes** stay on their host until the ember is destroyed; nothing
  archives them to object storage.

## What has not been exercised

Bringing this up on a second host, or in a second location, will go through
code paths that have never run: templates built on more than one host, a
ember resumed on a host other than its volume's, ACME issuing the wildcard
certificate, and a load balancer with more than one member. Everything in
steps 0 to 7 has been run end to end.
