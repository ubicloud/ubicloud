# GCP Network Firewall Architecture

## Overview

Ubicloud uses [GCP Network Firewall Policies](https://cloud.google.com/firewall/docs/network-firewall-policies)
to implement per-VM firewalls on GCP. A single firewall policy is attached to each
VPC and contains all rules for all subnets and VMs in that VPC. Rules are
differentiated using **GCP Secure Tags**: each rule targets a specific tag value,
and only VMs whose NICs are bound to that tag value evaluate the rule.

GCP firewall policies have a flat priority space (0-65535) where **lower number =
higher precedence**. We partition this space into three bands (see [Priority
Bands](#priority-bands)).

## Ubicloud Data Model

Firewalls in Ubicloud are ordinary ORM objects. Three relevant tables:

| Table | Role |
|-------|------|
| `firewall` | Named bag of firewall rules. |
| `firewalls_private_subnets` | M:N, attaches a firewall to a subnet. |
| `vm_firewall` | M:N, attaches a firewall directly to one VM (legacy path). |

A VM's **effective** firewall set is the union of both paths
(`model/vm.rb:108-110`):

```ruby
def firewalls(opts = {})
  private_subnet_firewalls(opts) + vm_firewalls(opts)
end
```

Two VMs in the same subnet normally have the same effective firewalls
(everything attached to their shared subnet). They diverge only when
`vm_firewall` binds a firewall directly to one of them.

Each firewall has `firewall_rule` rows of `(cidr, protocol, port_range)`. The
`cidr` may be IPv4 or IPv6. We do not distinguish families at the Ubicloud
layer; both partition naturally at the GCP layer via the source CIDR.

## GCP Mapping

Three GCP concepts must be held together to read this implementation.

### Network Firewall Policy

One policy per VPC, created by `Prog::Vnet::Gcp::VpcNexus`. The policy is a
flat, priority-ordered list of rules; each rule has:

- `direction`: INGRESS or EGRESS
- `action`: allow or deny
- `priority`: globally unique inside the policy
- `target_secure_tags`: the rule only matches VMs bound to these tag values
- `src_ip_ranges` / `dest_ip_ranges`
- `layer4_configs`: list of `{ip_protocol, ports}`

Two load-bearing constraints from GCP:

- **Priorities are globally unique inside a policy.** GCP rejects duplicate
  priorities with `InvalidArgumentError: same priorities`. Tag targeting
  decides who evaluates a rule; it does not let two rules share a priority.
- **A NIC can have at most 10 tag bindings.** See
  [Sharp Edges](#sharp-edges).

### Secure Tags

A `(tag_key, tag_value)` pair. We create two kinds:

| Kind | Tag Key | Tag Value | Created By | Bound To |
|------|---------|-----------|------------|----------|
| Subnet | `ubicloud-subnet-{subnet.ubid}` | `member` | `SubnetNexus#create_tag_resources` | Every NIC in that subnet. |
| Firewall | `ubicloud-fw-{firewall.ubid}` | `active` | `UpdateFirewallRules#ensure_firewall_tag_key/ensure_tag_value` | Every NIC whose VM has that firewall in its effective set. |

Firewall tag keys are created with `purpose: GCE_FIREWALL` and
`purpose_data: {"network" => <vpc_network_self_link>}` so they are scoped to
the VPC.

### Tag Bindings

A `TagBinding` binds a VM NIC (`//compute.googleapis.com/.../instances/{name}`)
to one tag value. `UpdateFirewallRules#sync_tag_bindings` maintains the
binding set for a given NIC to match the VM's desired tags.

## Priority Bands

```
Priority Range   Band                   Purpose
--------------   --------------------   ----------------------------------------
1000 - 8999      Subnet ALLOW EGRESS    Intra-subnet traffic for tagged VMs
10000 - 59999    Per-firewall INGRESS   Tag-targeted allow rules per firewall
65531 - 65534    VPC-wide DENY          Block private traffic by default
```

### Layer 1: VPC-wide DENY (priorities 65531-65534)

Created by `SubnetNexus#create_vpc_deny_rules`. Four rules block all RFC 1918
and GCE internal IPv6 traffic (both INGRESS and EGRESS) for **every VM** in
the VPC. No `target_secure_tags` (they match all VMs unconditionally).

| Priority | Direction | IP Ranges |
|----------|-----------|-----------|
| 65534    | INGRESS   | RFC 1918 (10/8, 172.16/12, 192.168/16) |
| 65533    | EGRESS    | RFC 1918 |
| 65532    | INGRESS   | GCE internal IPv6 (fd20::/20) |
| 65531    | EGRESS    | GCE internal IPv6 |

This establishes a default-deny posture **for private traffic**: no private
traffic flows unless explicitly allowed by a higher-precedence (lower
priority number) rule. Public-internet INGRESS is **not** covered by these
rules; see [Sharp Edges](#sharp-edges).

### Layer 2: Subnet ALLOW EGRESS (priorities 1000-8998)

Created by `SubnetNexus#create_subnet_allow_rules`. Each `PrivateSubnet` is
assigned an **even** priority P in 1000..8998 and produces two rules:

| Priority | Direction | Target | Effect |
|----------|-----------|--------|--------|
| P        | EGRESS    | `ubicloud-subnet-{s.ubid}/member` | Allow IPv4 egress to subnet's net4 |
| P+1      | EGRESS    | `ubicloud-subnet-{s.ubid}/member` | Allow IPv6 egress to subnet's net6 |

Subnets get the n/n+1 pair because a subnet always has exactly one IPv4 CIDR
and one IPv6 CIDR. The pair together lets a VM inside the subnet speak to
every other VM in the same subnet (both families) while the Layer 1 DENY
rules block any other private traffic.

**Priority allocation** (`SubnetNexus#allocate_subnet_firewall_priority`):
scans existing priorities for the same `(project, location)` pair, picks the
first unused even number in 1000..8998, and atomically claims it via the
`private_subnet_firewall_priority_unique` DB unique constraint. With 4000
even slots (1000, 1002, ..., 8998), up to **4000 subnets per project per
location** are supported. Stored on `private_subnet.firewall_priority`, with
a CHECK constraint `firewall_priority % 2 = 0 AND firewall_priority BETWEEN
1000 AND 8998`.

### Layer 3: Per-firewall INGRESS (priorities 10000+)

Created by `UpdateFirewallRules#sync_firewall_rules`. Each Ubicloud
`Firewall` object gets its own GCP secure tag (`ubicloud-fw-{fw.ubid}/active`)
and one or more INGRESS allow rules targeting that tag.

**Rule compilation** (`build_tag_based_policy_rules`): Ubicloud
`FirewallRule` rows are grouped by `r.cidr.to_s`, so one GCP policy rule is
emitted per distinct source CIDR in a firewall's rules. Every
(protocol, port_range) pair sharing that CIDR collapses into the rule's
`layer4_configs` list. Because `src_ip_ranges` accepts both IPv4 and IPv6,
mixed-family source CIDRs naturally partition by family, one policy rule per
CIDR.

One firewall therefore takes as many priority slots as it has distinct source
CIDRs. This is **not** the n/n+1 pattern used by Layer 2: firewalls have no
fixed per-family shape, so no pairing makes sense.

**Priority allocation** (`sync_tag_policy_rules`): reads the current policy,
collects the priority set used by **every** rule (not just this firewall's),
and assigns the next free integer starting from `TAG_RULE_BASE_PRIORITY =
10000`. Priorities are not stored in the DB. Content-based diffing ignores
priority, so rules are recreated only when `(cidr, protocols, ports)`
actually change, not when priorities shift during unrelated additions or
deletions.

**VM binding**: `UpdateFirewallRules#sync_tag_bindings` ensures the VM's NIC
is bound to every `active` tag for firewalls in its effective set, plus the
subnet's `member` tag.

## Worked Example: Multi-VM, Multi-Firewall

This is the asymmetry the rest of the implementation rests on: two VMs in
the same subnet can see different effective rulesets because tag bindings
are per-NIC.

### Setup

```
Subnet S (firewall_priority 1000, tag: ubicloud-subnet-sS/member)

  F1 attached to S
    TCP 5432 from 10.0.0.0/8     (private clients)
    TCP 22   from 0.0.0.0/0      (open SSH)

  F2 attached to S
    TCP 443  from 0.0.0.0/0      (open HTTPS)

  F3 attached directly to VM-B (vm_firewall)
    TCP 80   from 192.168.0.0/16 (internal HTTP)

VMs:
  VM-A in S, effective firewalls = {F1, F2}
  VM-B in S, effective firewalls = {F1, F2, F3}
```

### Policy rules created (shared across all VMs in the VPC)

```
Priority  Dir     Action  Target Tag         Match
--------  ------  ------  -----------------  ------------------------------
1000      EGRESS  ALLOW   sub-S/member       IPv4 egress to S.net4
1001      EGRESS  ALLOW   sub-S/member       IPv6 egress to S.net6
10000     INGRESS ALLOW   fw-F1/active       src 10.0.0.0/8,   tcp:5432
10001     INGRESS ALLOW   fw-F1/active       src 0.0.0.0/0,    tcp:22
10002     INGRESS ALLOW   fw-F2/active       src 0.0.0.0/0,    tcp:443
10003     INGRESS ALLOW   fw-F3/active       src 192.168.0.0/16, tcp:80
65531     EGRESS  DENY    (no tag)           GCE internal IPv6
65532     INGRESS DENY    (no tag)           GCE internal IPv6
65533     EGRESS  DENY    (no tag)           RFC 1918
65534     INGRESS DENY    (no tag)           RFC 1918
```

These rules **exist once** in the shared VPC policy regardless of how many
VMs are affected. The per-VM effect comes entirely from which tags each
NIC is bound to.

### Tag bindings per NIC

```
VM-A NIC: { sub-S/member, fw-F1/active, fw-F2/active }
VM-B NIC: { sub-S/member, fw-F1/active, fw-F2/active, fw-F3/active }
```

VM-A is missing `fw-F3/active`, so the rule at priority 10003 is **invisible**
to VM-A during evaluation.

### Evaluation traces

GCP walks rules low-to-high priority. For each rule, if any of its
`target_secure_tags` is not bound to the evaluating NIC, the rule is skipped.

**VM-A receives inbound TCP 5432 from 10.0.0.5:**
1. 1000-1001: EGRESS, skip.
2. 10000: target `fw-F1/active`, VM-A bound; src 10.0.0.0/8 matches; tcp:5432 matches. **ALLOW**.

**VM-A receives inbound TCP 80 from 10.0.0.5:**
1. 1000-1001: EGRESS, skip.
2. 10000: `fw-F1/active` matches, src matches, but layer4 is tcp:5432. Skip.
3. 10001: `fw-F1/active` matches, src 0.0.0.0/0 matches, but layer4 is tcp:22. Skip.
4. 10002: `fw-F2/active` matches, src matches, but layer4 is tcp:443. Skip.
5. 10003: `fw-F3/active`, **VM-A not bound**. Skip.
6. 65534: INGRESS DENY RFC 1918, src 10.0.0.5 matches. **DENY**.

**VM-B receives inbound TCP 80 from 192.168.1.5:**
1. 10000-10002: no port match.
2. 10003: `fw-F3/active`, **VM-B bound**; src 192.168.0.0/16 matches; tcp:80 matches. **ALLOW**.

This is the core asymmetry: same subnet, same F1 and F2, but VM-B gets F3
and VM-A does not, purely because VM-B's NIC has the `fw-F3/active` binding.

## Lifecycle

Rule-set changes always manifest as a `update_firewall_rules` semaphore bump
on each affected VM's strand. The prog then re-runs `update_firewall_rules`,
which is fully idempotent and content-diffing: the shared policy converges
to the desired state, and each NIC's tag binding set converges to the set
derived from the VM's current effective firewalls.

### Attaching a firewall to a subnet

`Firewall#associate_with_private_subnet` (`model/firewall.rb:67`) takes the
subnet lock, validates per-VM cap, inserts `firewalls_private_subnets`, and
increments `update_firewall_rules` on the subnet. `SubnetNexus#wait`
propagates the bump to every VM in the subnet's `vms_dataset`. Each VM's
`UpdateFirewallRules` run:

1. Iterates `vm.firewalls` (now including the new firewall).
2. Ensures the firewall's tag key and `active` tag value exist. Concurrent
   attempts race via `AlreadyExists` lookup (idempotent).
3. Syncs the firewall's rules into the shared policy (idempotent across
   concurrent VMs, because `sync_tag_policy_rules` content-diffs).
4. Adds the firewall's `active` tag value to the NIC's desired binding set
   and calls `sync_tag_bindings`.

### Detaching a firewall from a subnet

`Firewall#disassociate_from_private_subnet` deletes the M:N row and bumps
the same semaphore. Each VM re-runs `update_firewall_rules`;
`vm.firewalls` no longer has the firewall, so `desired_tag_values` omits
its `active` tag. `sync_tag_bindings` deletes the stale binding from the
NIC.

Rules in the shared policy for that firewall remain until
`cleanup_orphaned_firewall_rules` (run at the tail of the same prog) drops
them. Orphan detection is based on whether any VM in the VPC still has
the firewall in its effective set.

### Editing a firewall's rules

`FirewallRule` insertion/deletion bumps `update_firewall_rules` on every VM
that references the firewall, directly or through the subnet. Each VM's
prog calls `sync_firewall_rules(fw.rules, tag_value_name)`, which
content-diffs desired vs. existing and applies the minimum edits. Priority
numbers may shift; semantics don't, because evaluation is by
`(target_tag, src_ip, layer4_configs)`, not by priority.

### VM destroy

When a VM is deleted, GCE removes its tag bindings along with the instance.
If `UpdateFirewallRules` happens to be queued or running at that moment,
`before_run` checks `vm.destroy_set?` and `pop`s without trying to mutate
tags or rules (per-VM tag bindings are gone with the instance anyway).
Cleanup of now-unused policy rules, tag values, and tag keys for firewalls
that have no remaining references runs opportunistically inside
`cleanup_orphaned_firewall_rules` when some other VM in the same VPC next
runs `UpdateFirewallRules`.

## Sharp Edges

### 10-tag NIC binding limit

GCE enforces a hard cap of 10 tag bindings per NIC, checked at request time
during `create_tag_binding`. A VM needs:

- 1 binding for `ubicloud-subnet-{s.ubid}/member`
- 1 binding per firewall in its effective set

So a VM can belong to at most **9 firewalls**. `update_firewall_rules`
truncates the desired set when it exceeds 10, keeping the subnet tag and
trimming firewalls to fit. The truncation emits a Clog warning
(`gcp_nic_tag_limit`).

A model-level validation that refuses to attach a 10th firewall to a GCP VM
is tracked as a follow-up so the truncation becomes a defensive backstop
rather than the primary guardrail.

### Tag-binding delete/create ordering

GCE checks the 10-tag limit at create time. If we try to create a new
binding while the NIC already has 10 (because a stale one hasn't been
deleted yet), GCE returns 400. Racing the deletes synchronously would not
help: GCE reads the current binding set for each request.
`sync_tag_bindings` handles this by:

1. Attempting creates. 400 with stale bindings present queues the failed
   creates for retry.
2. Issuing the stale deletes as LROs. Collects the op names.
3. If any creates failed, hops to `wait_tag_binding_deletes`, polls each
   delete op to DONE, then retries the failed creates from the queue.

If there are no stale bindings, the 400 is not a capacity issue and
propagates.

### Concurrent firewall sync across VMs

Two VMs attaching to the same firewall at the same time both call
`ensure_firewall_tag_key` and `ensure_tag_value`. The losing transaction
sees `Google::Cloud::AlreadyExistsError`; `ensure_*` catches that and
falls through to `lookup_*_name!` to return the already-created name.
Same pattern inside `create_tag_policy_rule` with `InvalidArgumentError:
same priorities` on priority collision: re-read the policy, pick a new
free slot, retry (up to 5 attempts).

### Orphan cleanup

`cleanup_orphaned_firewall_rules` (at the tail of
`UpdateFirewallRules#update_firewall_rules`) lists the VPC's firewall tag
keys (filtered to `purpose == GCE_FIREWALL` scoped to this VPC's network),
pairs each with its firewall UUID, and excludes any that are still
referenced by `firewalls_private_subnets` or `firewalls_vms` in the DB.
For each orphaned firewall, it deletes the policy rules targeting that
firewall's `active` tag value, then deletes the tag value and tag key.


### Public-internet INGRESS is not blocked by default

The Layer 1 DENY rules only cover RFC 1918 and GCE internal IPv6. A VM
with a public IPv4 (assigned via `AssignedVmAddress`) receives
public-internet traffic unless explicitly blocked by a firewall rule at a
lower priority number. This matches AWS Security Group semantics
(explicit ALLOW, implicit block when the policy evaluation falls through
with no match; GCP Network Firewall Policies then defer to the next-lower
policy in the chain or the default VPC firewall).

If stronger isolation is needed, add a `FirewallRule` with the desired
source CIDR and **no** matching port to force explicit coverage, or add a
VPC-wide INGRESS DENY rule for `0.0.0.0/0` and `::/0` at the tail of
Layer 1 (not done currently).

## Priority Allocation Mechanics (summary)

### Subnet priorities (DB-backed)

Stored in `private_subnet.firewall_priority`. Allocation is optimistic:

1. Query all used priorities for the same `(project, location)`.
2. Find the first free even number in 1000..8998.
3. `UPDATE private_subnet SET firewall_priority = ?`.
4. If a `Sequel::UniqueConstraintViolation` occurs (concurrent allocation),
   retry up to 5 times.

### Per-firewall rule priorities (policy-backed)

Not stored in the DB. `UpdateFirewallRules#sync_tag_policy_rules` reads the
current policy on every sync, finds all used priorities, and picks free
slots starting from 10000. Content-based diffing (ignoring priority)
ensures rules are only created/deleted when their actual content changes.

## Implementation Files

| File | Responsibility |
|------|---------------|
| `prog/vnet/gcp/vpc_nexus.rb` | VPC + firewall policy lifecycle, tag key/value deletion at destroy |
| `prog/vnet/gcp/subnet_nexus.rb` | Subnet, subnet tag key/value, deny rules, subnet allow rules, priority allocation |
| `prog/vnet/gcp/update_firewall_rules.rb` | Per-firewall tag key/value, INGRESS rules, tag bindings, orphan cleanup |
| `prog/vnet/gcp/nic_nexus.rb` | NIC lifecycle, static IP allocation (no firewall responsibility) |
| `model/firewall.rb` | `associate_with_private_subnet`, per-VM cap validation |
| `model/vm.rb` | `vm.firewalls = private_subnet_firewalls + vm_firewalls` |
