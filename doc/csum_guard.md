# Checksum guard

If a packet with bad checksum metadata gets into a host's IPv4 stack,
`skb_checksum_help()` can corrupt its network header. Upstream Linux
fixes this in 6785011f8b16 ("ipv4: validate checksum_start before
completing checksum").

VM taps are where guest packets enter a host, so the checksum guard
applies the upstream test at tc ingress of each tap and drops such
packets before the stack sees them. Well-formed packets pass. It is
defence in depth for hosts that do not run a patched kernel yet.

## The program

The eBPF program, its tests, and its benchmark live in the
`ubicloud/csum-guard` repository. A release tag there builds one CO-RE
object, `csum_guard.bpf.o`, and attaches it with its SHA-256 to the
GitHub release. The object relocates against each host's BTF at load,
so one asset serves every kernel from 6.3 on, which
`bpf_cast_to_kern_ctx` needs, and both architectures.

`CsumGuardSetup::VERSION` and `CsumGuardSetup::OBJECT_SHA256` pin the
release. The host loads the object with `tc`, which iproute2 links
against libbpf, so a host needs no compiler and no bpftool.

## Operational surface

Two `VmHost` semaphores turn the guard on and off on existing hosts.
A new host installs the guard during `HostNexus#prep`, before it
accepts VMs. A deploy or a rhizome rollout changes no existing host.

- `enable_csum_guard`: `HostNexus#wait` pushes `Prog::SetupCsumGuard`,
  which runs `host/bin/setup-csum-guard install`. That refuses kernels
  older than 6.3, downloads and verifies the pinned object, proves it
  loads on a tap in a throwaway namespace, places it at
  `/opt/csum-guard/csum_guard-<version>.bpf.o`, and attaches it to every
  tap in a named network namespace.
- `disable_csum_guard`: the same prog runs
  `host/bin/setup-csum-guard uninstall`, which removes that object and
  detaches the filter from every tap.

Only after the command succeeds does the prog set
`vm_host.csum_guard_enabled`, so the column records what the host runs
and never just what was asked for. `HostNexus` decrements the semaphore
once the prog returns. A host with both semaphores set ends up without
the guard.

While the object exists, `VmSetup#interfaces` attaches the filter to the
taps of each VM it creates, and to the taps it rebuilds when a VM
restarts after a host reboot. Filters do not survive a reboot, but
taps do not either, so no boot unit is needed.

VM creation never waits for an install or uninstall, which can take a
while on a host with many VMs. `/run/lock/csum-guard.lock` keeps only
install and uninstall apart. A VM created during an install is guarded
either by its own attach or by the install's walk over the taps. A VM
created during an uninstall can keep the filter, which is harmless;
running uninstall again removes it. Both walks skip VMs deleted under
them. A VM fails to start if its taps cannot get the filter while the
guard is installed, which the probe at install makes unlikely.

The filter sits at `pref 49152` of the tap's clsact ingress hook.
Inspect it, and its drop counter, on a host with:

```sh
sudo tc -n <vm-netns> filter show dev <tap> ingress
```

Each attached filter has its own `counters` map; index 0 counts dropped
packets. Hosts do not ship bpftool, so read it where bpftool is
installed with `bpftool map dump name counters`.

## Rollout

1. Deploy the migration, then the code. The column is false on every
   host and nothing sets the semaphores on existing hosts, so no host
   changes. New hosts get the guard during prep.
2. Roll rhizome out (`Prog::RolloutRhizome`), which puts
   `setup-csum-guard` and the `VmSetup` hook on the hosts. The hook
   does nothing until a host is installed.
3. Roll the guard out with `Prog::RolloutSemaphore`, which sets the
   semaphore on one host at a time and waits for each to finish:

   ```ruby
   Prog::RolloutSemaphore.assemble(semaphore: "enable_csum_guard",
     ids: VmHost.where(...).select_map(:id), wait: "wait")
   ```

   Its `pause` semaphore stops the rollout. A host whose install keeps
   failing pages after ten minutes, for example on a kernel older than
   6.3, and holds the rollout there. The `csum_guard_enabled` column
   then shows which hosts have it.

## Revert

Turn the guard off and detach it from every tap, without a deploy, on
one host:

```ruby
vm_host.incr_disable_csum_guard
```

or on many, with a rollout of `disable_csum_guard` as above. To stop a
rollout of `enable_csum_guard` midway, pause it, and roll
`disable_csum_guard` over the hosts it already reached.

To remove the feature, revert the commit that added it and drop the
column with a new migration.

## Upgrading the program

Tag a new release in `ubicloud/csum-guard`, then bump `VERSION` and
`OBJECT_SHA256` together. After rhizome rolls out, roll
`enable_csum_guard` again over the hosts with `csum_guard_enabled`:
install downloads the new version and replaces the filter on every tap.
Do it right after the rhizome rollout. Until a host is reinstalled,
`VmSetup` looks for the new version's object, which is not there yet,
so VMs created on it in between do not get the guard. The old object
stays on disk and is ignored.

## Testing

The program's own tests run in `ubicloud/csum-guard`: a netns rig that
injects packets through an `IFF_VNET_HDR` tap and asserts from the drop
counter that bad packets are dropped and good ones pass. Rhizome's
specs cover the commands `CsumGuardSetup` runs.
