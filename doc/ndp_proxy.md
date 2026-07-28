# Route-following NDP proxy

## Problem

Some providers deliver a host's IPv6 network on-link instead of routing
it: their router multicasts a Neighbor Solicitation for every individual
destination address and only delivers traffic after receiving a Neighbor
Advertisement. Such hosts have `vm_host.ndp_needed` set.

None of the addresses delegated to VMs are configured on any host
interface; they exist only as routes into each VM's network namespace
(`route <ephemeral_net6> via <vethi link-local> dev vetho<vm>`). The
kernel therefore answers NS for none of them. Linux's built-in remedy,
`proxy_ndp`, is an exact-match /128 registry (`ip -6 neigh add proxy`)
with no prefix or route-following mode, so it forces the control plane
to enumerate every address a guest may use. That caps guests at the two
enumerated addresses and is exactly the per-address bookkeeping IPv4
never needed: proxy ARP answers by consulting the routing table.

## Design

An eBPF program on the uplink's tc ingress hook gives NDP the same
routing-driven semantics. The program, its map layouts, and the loader
that writes them live together in [ubicloud/host-ebpf][host-ebpf],
released as a static binary; nothing about the eBPF is split across
repositories.

[host-ebpf]: https://github.com/ubicloud/host-ebpf

```
NS "who has T?"  ->  bpf_fib_lookup(T)  ->  egress != uplink?  ->  NA "T is at <uplink MAC>"
                                        ->  anything else      ->  pass to the kernel stack
```

Case analysis for a host with `net6 = 2a01:db8:aa::/64`:

| NS target                | best FIB match             | action |
|--------------------------|----------------------------|--------|
| addr in a live VM's /79  | `/79 dev vetho<vm>`        | answer |
| unallocated addr in net6 | on-link /64 on the uplink  | silent |
| host's own address       | local (`NOT_FWDED`)        | silent; the kernel answers natively |
| anything else            | default route (uplink)     | silent |

The routing table is the only registry: VM create/destroy already
installs and removes the routes, so delegating the guest's entire /80
requires no additional state anywhere. An LPM map holding the host's
`net6` bounds what the program may ever answer, independent of FIB
content.

Protocol rules, all matching what the kernel responder this preempts
would do: a solicitation is ignored unless its hop limit is 255
(RFC 4861 7.1.1, rejecting off-link forgery) and its ICMPv6 checksum
verifies. NS with an unspecified source is duplicate address detection
and is never defended, so a node that legitimately holds a delegated
address can still claim it. The NA carries Router|Solicited with
Override clear (RFC 4861 7.2.4: a proxy must let an actual owner win
the neighbor cache), is sourced from the target, and mirrors the
solicitation's source link-layer option as a target link-layer option.
An optionless NS - a unicast NUD probe - is answered without a TLL,
keeping the rewrite size-preserving; a multicast solicitation without
that option is left alone, since its advertisement would be required
to carry a TLL that does not fit. The program never drops: every non-answer path returns `TC_ACT_UNSPEC` so
the stack still sees the packet, and when it does answer, the redirect
consumes the NS so static proxy entries cannot double-answer.

The uplink runs with allmulticast on: initial solicitations arrive on
solicited-node multicast groups derived from the target's low 24 bits,
which cannot be joined ahead of time for a /80, and the NIC's hardware
filter would otherwise drop them before tc runs.

## Operational surface

`Prog::SetupNdpProxy` (budded from `Prog::Vm::HostNexus#prep` when
`ndp_needed`) runs `host/bin/setup-ndp-proxy install <net6>`, which
downloads the pinned host-ebpf release, verifies its SHA-256 the way
`CloudHypervisor` does, and writes and enables the units below. The
binary refuses to attach on kernels older than 6.6, which TCX links
require.

- `ndp-proxy.service` (oneshot, at boot): `setup-ndp-proxy apply`,
  which resolves the uplink from the IPv6 default route and runs
  `host-ebpf ndp-proxy apply`. Program and maps are pinned under
  `/sys/fs/bpf/ndp-proxy`, and neither pins nor attachments survive a
  reboot, so this unit restores them with no control-plane
  involvement.
- `ndp-proxy-watch.timer`, and the `ndp-proxy-watch.service` it
  triggers every minute: `setup-ndp-proxy verify`, which runs
  `host-ebpf ndp-proxy verify -heal`. That prints the counters when
  nothing drifted; on drift it names what drifted, prints the counters
  it is about to lose, re-applies, and exits non-zero so the unit
  failure stays visible in `systemctl --failed`.

Both units fetch the release themselves rather than assuming an
install placed it, so bumping `NdpProxySetup::VERSION` and rolling out
rhizome upgrades hosts that were provisioned before the bump.

Rhizome owns only host policy: which hosts get the proxy, which device
is the uplink, and when to install. Everything about the eBPF itself is
behind the binary's command line.

An attached program cannot crash; the failure modes are "never
attached", "detached", and "allmulticast cleared", all of which decay
slowly as the provider router's neighbor cache expires - hence the
watch timer rather than a liveness check on a daemon.

## Migration

The proxy coexists with the legacy per-/128 entries `vm_setup.rb` adds
for `ndp_needed` VMs (`guest_ephemeral.nth(2)`,
`clover_ephemeral.nth(0)`). Once every `ndp_needed` host runs the
proxy, those `ip -6 neigh add proxy` calls and the `ndp_needed`
plumbing through `params_json`/`setup-vm` can be deleted; stale kernel
entries are harmless and die on reboot. `vm_host.ndp_needed` remains as
the host-scoped "install the responder" flag.

## Testing

The program's own tests live in host-ebpf: a two-netns rig that drives
the released binary on the wire, plus unit tests pinning the map
layouts against the compiled object. Rhizome's specs cover what
rhizome owns - digest-verified download, unit contents, and the
commands handed to the binary.

## Boundary

This is the first consumer of host-ebpf. The standing rule for what
else may move there: stateless per-packet decisions at the uplink edge
(next: the `drop_unused_ip_packets` nftables table, whose per-VM
allowlist becomes atomic pinned-map updates instead of
`/etc/nftables.d` fragments plus a global `systemctl reload`).
Anything that relies on conntrack - NAT44, the load balancer DNAT
mesh, established/related firewall semantics - stays in nftables.
