# GCP Network Firewall Architecture

## Overview

Ubicloud uses [GCP Network Firewall
Policies](https://cloud.google.com/firewall/docs/network-firewall-policies)
to implement per-VM firewalls on GCP. A single firewall policy is
attached to each VPC and contains all rules for all subnets and VMs in
that VPC. Rules are differentiated using **GCP Secure Tags**: each rule
targets a specific tag value, and only VMs bound to that tag value
evaluate the rule.

GCP firewall policy rule priorities are non-negative integers where
**lower number = higher precedence**. We use the range 0-65535 (the
priority allocator caps every new rule at 65535) and partition it into
three bands (see [Priority Bands](#priority-bands)).

## Ubicloud Data Model

Firewalls in Ubicloud are ordinary ORM objects. Three relevant tables:

| Table | Role |
|-------|------|
| `firewall` | Named bag of firewall rules. |
| `firewalls_private_subnets` | M:N, attaches a firewall to a subnet. |
| `firewalls_vms` | M:N, attaches a firewall directly to one VM (legacy path). |

A VM's **effective** firewall set is the union of both paths
(`model/vm.rb:110-112`):

```ruby
def firewalls(opts = {})
  private_subnet_firewalls(opts) + vm_firewalls(opts)
end
```

Two VMs in the same subnet normally have the same effective firewalls
(everything attached to their shared subnet). They diverge only when
`firewalls_vms` binds a firewall directly to one of them.

Each firewall has `firewall_rule` rows of `(cidr, protocol,
port_range)`. The `cidr` may be IPv4 or IPv6. We do not distinguish
families at the Ubicloud layer; both partition naturally at the GCP
layer via the source CIDR.

## GCP Mapping

Three GCP concepts must be held together to read this implementation.

### Network Firewall Policy

One policy per VPC, created by `Prog::Vnet::Gcp::VpcNexus`. The policy
is a flat, priority-ordered list of rules; each rule has:

- `direction`: INGRESS or EGRESS
- `action`: allow or deny
- `priority`: globally unique inside the policy
- `target_secure_tags`: the rule only matches VMs bound to these tag
  values
- `src_ip_ranges` / `dest_ip_ranges`
- `layer4_configs`: list of `{ip_protocol, ports}`

Two load-bearing constraints from GCP:

- **Priorities are globally unique inside a policy.** GCP rejects
  duplicate priorities with `InvalidArgumentError: same priorities`. Tag
  targeting decides who evaluates a rule; it does not let two rules
  share a priority.
- **A VM (Compute instance) can have at most 10 tag bindings.** See
  [Sharp Edges](#sharp-edges).

### Secure Tags

A `(tag_key, tag_value)` pair. We create two kinds:

| Kind | Tag Key | Tag Value | Created By | Bound To |
|------|---------|-----------|------------|----------|
| Subnet | `ubicloud-subnet-{subnet.ubid}` | `active` | `SubnetNexus#create_tag_resources` | Every VM in that subnet. |
| Firewall | `ubicloud-fw-{firewall.ubid}` | `active` | `VpcUpdateFirewallRules#ensure_firewall_tag_key/ensure_tag_value` | Every VM that has that firewall in its effective set. |

Firewall tag keys are created with `purpose: GCE_FIREWALL` and
`purpose_data: {"network" => <vpc_network_self_link>}` so they are
scoped to the VPC.

### Tag Bindings

A `TagBinding` binds a VM (Compute instance, parent path
`//compute.googleapis.com/.../instances/{id}`) to one tag value.
`UpdateFirewallRules#update_firewall_rules` maintains the binding set
for a given VM to match its desired tags.

## Priority Bands

```
Priority Range   Band                   Purpose
--------------   --------------------   ----------------------------------------
1000 - 8999      Subnet ALLOW EGRESS    Intra-subnet traffic for tagged VMs
10000 - 65530    Per-firewall INGRESS   Tag-targeted allow rules per firewall
65531 - 65534    VPC-wide DENY          Block private traffic by default
```

### Layer 1: VPC-wide DENY (priorities 65531-65534)

Created by `VpcNexus#create_vpc_deny_rules`. Four rules block all RFC
1918 and GCE internal IPv6 traffic (both INGRESS and EGRESS) for **every
VM** in the VPC. No `target_secure_tags` (they match all VMs
unconditionally).

| Priority | Direction | IP Ranges |
|----------|-----------|-----------|
| 65534    | INGRESS   | RFC 1918 (10/8, 172.16/12, 192.168/16) |
| 65533    | EGRESS    | RFC 1918 |
| 65532    | INGRESS   | GCE internal IPv6 (fd20::/20) |
| 65531    | EGRESS    | GCE internal IPv6 |

This establishes a default-deny posture **for private traffic**: no
private traffic flows unless explicitly allowed by a higher-precedence
(lower priority number) rule. Public-internet INGRESS is **not** covered
by these rules; see [Sharp Edges](#sharp-edges).

### Layer 2: Subnet ALLOW EGRESS (priorities 1000-8999)

Created by `SubnetNexus#create_subnet_allow_rules`. Each `PrivateSubnet`
is assigned an **even** priority P in 1000..8998 and produces two rules:

| Priority | Direction | Target | Effect |
|----------|-----------|--------|--------|
| P        | EGRESS    | `ubicloud-subnet-{s.ubid}/active` | Allow IPv4 egress to subnet's net4 |
| P+1      | EGRESS    | `ubicloud-subnet-{s.ubid}/active` | Allow IPv6 egress to subnet's net6 |

Subnets get the n/n+1 pair because a subnet always has exactly one IPv4
CIDR and one IPv6 CIDR. The pair together lets a VM inside the subnet
speak to every other VM in the same subnet (both families) while the
Layer 1 DENY rules block any other private traffic.

**Priority allocation**
(`SubnetNexus#allocate_subnet_firewall_priority`): scans existing
priorities for the same `(project, location)` pair, picks the first
unused even number in 1000..8998, and `UPDATE`s
`private_subnet.firewall_priority` to claim it. The
`private_subnet_project_location_firewall_priority_idx` partial unique
index on `(project_id, location_id, firewall_priority)` (where
`firewall_priority IS NOT NULL`) enforces uniqueness; concurrent racers
that pick the same slot lose with `Sequel::UniqueConstraintViolation`,
which crashes the strand label. The strand machinery re-executes the
label, the losing strand re-scans against the now-updated used set, and
progress is eventual. With 4000 even slots (1000, 1002, ..., 8998), up
to **4000 subnets per project per location** are supported. Stored on
`private_subnet.firewall_priority`, with a CHECK constraint
`firewall_priority % 2 = 0 AND firewall_priority BETWEEN 1000 AND 8998`.

### Layer 3: Per-firewall INGRESS (priorities 10000+)

Created by `VpcUpdateFirewallRules#sync_firewall_rules`. Each Ubicloud
`Firewall` object gets its own GCP secure tag
(`ubicloud-fw-{fw.ubid}/active`) and one or more INGRESS allow rules
targeting that tag.

**Rule compilation** (`build_tag_based_policy_rules`): Ubicloud
`FirewallRule` rows are grouped by `r.cidr.to_s`, so one GCP policy rule
is emitted per distinct source CIDR in a firewall's rules. Every
(protocol, port_range) pair sharing that CIDR collapses into the rule's
`layer4_configs` list. Because `src_ip_ranges` accepts both IPv4 and
IPv6, mixed-family source CIDRs naturally partition by family, one
policy rule per CIDR.

One firewall therefore takes as many priority slots as it has distinct
source CIDRs. This is **not** the n/n+1 pattern used by Layer 2:
firewalls have no fixed per-family shape, so no pairing makes sense.

**Priority allocation** (`sync_tag_policy_rules`): reads the current
policy, collects the priority set used by **every** rule (not just this
firewall's), and assigns the next free integer starting from
`TAG_RULE_BASE_PRIORITY = 10000`. Priorities are not stored in the DB.
Content-based diffing ignores priority, so rules are recreated only when
`(cidr, protocols, ports)` actually change, not when priorities shift
during unrelated additions or deletions.

**VM binding**: `UpdateFirewallRules#update_firewall_rules` ensures the
VM is bound to every `active` tag for firewalls in its effective set
that have any rules, plus the subnet's `active` tag. Firewalls with
zero rules are intentionally skipped; binding their tag would have no
matching policy rule and just consume one of the 10 per-VM tag slots.

## Worked Example: Multi-VM, Multi-Firewall

This is the asymmetry the rest of the implementation rests on: two VMs
in the same subnet can see different effective rulesets because tag
bindings are per-VM.

### Setup

```
Subnet S (firewall_priority 1000, tag: ubicloud-subnet-sS/active)

  F1 attached to S
    TCP 5432 from 10.0.0.0/8     (private clients)
    TCP 22   from 0.0.0.0/0      (open SSH)

  F2 attached to S
    TCP 443  from 0.0.0.0/0      (open HTTPS)

  F3 attached directly to VM-B (firewalls_vms)
    TCP 80   from 192.168.0.0/16 (internal HTTP)

VMs:
  VM-A in S, effective firewalls = {F1, F2}
  VM-B in S, effective firewalls = {F1, F2, F3}
```

### Policy rules created (shared across all VMs in the VPC)

```
Priority  Dir     Action  Target Tag         Match
--------  ------  ------  -----------------  ------------------------------
1000      EGRESS  ALLOW   sub-S/active       IPv4 egress to S.net4
1001      EGRESS  ALLOW   sub-S/active       IPv6 egress to S.net6
10000     INGRESS ALLOW   fw-F1/active       src 10.0.0.0/8,   tcp:5432
10001     INGRESS ALLOW   fw-F1/active       src 0.0.0.0/0,    tcp:22
10002     INGRESS ALLOW   fw-F2/active       src 0.0.0.0/0,    tcp:443
10003     INGRESS ALLOW   fw-F3/active       src 192.168.0.0/16, tcp:80
65531     EGRESS  DENY    (no tag)           GCE internal IPv6
65532     INGRESS DENY    (no tag)           GCE internal IPv6
65533     EGRESS  DENY    (no tag)           RFC 1918
65534     INGRESS DENY    (no tag)           RFC 1918
```

These rules **exist once** in the shared VPC policy regardless of how
many VMs are affected. The per-VM effect comes entirely from which tags
each VM is bound to.

### Tag bindings per VM

```
VM-A: { sub-S/active, fw-F1/active, fw-F2/active }
VM-B: { sub-S/active, fw-F1/active, fw-F2/active, fw-F3/active }
```

VM-A is missing `fw-F3/active`, so the rule at priority 10003 is
**invisible** to VM-A during evaluation.

### Evaluation traces

GCP walks rules low-to-high priority. For each rule, if any of its
`target_secure_tags` is not bound to the evaluating VM, the rule is
skipped.

**VM-A receives inbound TCP 5432 from 10.0.0.5:**
1. 1000-1001: EGRESS, skip.
2. 10000: target `fw-F1/active`, VM-A bound; src 10.0.0.0/8 matches;
   tcp:5432 matches. **ALLOW**.

**VM-A receives inbound TCP 80 from 10.0.0.5:**
1. 1000-1001: EGRESS, skip.
2. 10000: `fw-F1/active` matches, src matches, but layer4 is tcp:5432.
   Skip.
3. 10001: `fw-F1/active` matches, src 0.0.0.0/0 matches, but layer4 is
   tcp:22. Skip.
4. 10002: `fw-F2/active` matches, src matches, but layer4 is tcp:443.
   Skip.
5. 10003: `fw-F3/active`, **VM-A not bound**. Skip.
6. 65534: INGRESS DENY RFC 1918, src 10.0.0.5 matches. **DENY**.

**VM-B receives inbound TCP 80 from 192.168.1.5:**
1. 10000-10002: no port match.
2. 10003: `fw-F3/active`, **VM-B bound**; src 192.168.0.0/16 matches;
   tcp:80 matches. **ALLOW**.

This is the core asymmetry: same subnet, same F1 and F2, but VM-B gets
F3 and VM-A does not, purely because VM-B has the `fw-F3/active`
binding.

## Lifecycle

Two distinct semaphore-fanout paths exist on GCP. They look similar at
the call sites but converge on different consumers, and conflating them
leads to the wrong mental model:

- **Rule-edit path** (`Firewall#update_private_subnet_firewall_rules`).
  `FirewallRule` inserts/deletes/replaces bump `update_firewall_rules`
  on each attached `private_subnet`. `Prog::Vnet::Gcp::SubnetNexus#wait`
  then forwards the bump to the subnet's `gcp_vpc` only (no per-VM
  fan-out): rule edits do not change tag bindings, so VMs do not need to
  re-run `UpdateFirewallRules`. The VPC's `VpcUpdateFirewallRules`
  reconciles tag keys/values, INGRESS policy rules, and orphan cleanup.
- **Membership-change path** (`Firewall#apply_firewalls_to_subnet`,
  invoked from `associate_with_private_subnet` and
  `disassociate_from_private_subnet`). On GCP this bypasses the subnet
  semaphore entirely: it bumps `update_firewall_rules` directly on the
  `gcp_vpc` and on every VM in the subnet's `vms_dataset`. The VPC
  reconciles shared policy, and each VM's `UpdateFirewallRules`
  reconciles its tag bindings against the new `vm.firewalls`.

The non-GCP path is symmetric but located differently: rule edits and
membership changes both bump the subnet semaphore, and the metal/AWS
nexus fans out to VMs (metal in `SubnetNexus#wait`, AWS in
`VpcNexus#wait`). For GCP, that subnet-level fan-out only carries rule
edits, and only to the VPC; per-VM bumps come straight from
`firewall.rb`.

Both progs are idempotent: the shared policy converges to the desired
state regardless of which strand runs first, and each VM's tag-binding
set converges to the set derived from `vm.firewalls`. Multiple in-flight
semaphore bumps coalesce into a single label run.

### Attaching a firewall to a subnet

`Firewall#associate_with_private_subnet` (`model/firewall.rb`) opens a
DB transaction, takes the subnet row lock, validates per-VM cap
(`Firewall.validate_gcp_firewall_cap!` against every VM currently in the
subnet), inserts `firewalls_private_subnets`, and calls
`apply_firewalls_to_subnet`. On GCP that helper bumps the VPC's
`update_firewall_rules` semaphore and bumps `update_firewall_rules` on
every VM in `private_subnet.vms_dataset` directly. The subnet semaphore
is **not** involved on GCP for membership changes. The two consumers
then run independently:

- **VPC-side (`VpcUpdateFirewallRules`):** ensures the firewall's tag
  key and `active` tag value exist (`AlreadyExists` is treated as
  idempotent success via fallback lookup), then syncs the firewall's
  rules into the shared policy.
- **Per-VM (`UpdateFirewallRules`):** rebuilds the VM's desired binding
  set from `vm.firewalls` and reconciles inline (creates first, then
  fire-and-forget deletes).

### Detaching a firewall from a subnet

`Firewall#disassociate_from_private_subnet` removes the
`firewalls_private_subnets` row and calls `apply_firewalls_to_subnet`,
which on GCP bumps the VPC and every VM in the subnet directly (same
fan-out shape as attach). Each VM re-runs `update_firewall_rules`;
`vm.firewalls` no longer contains the detached firewall, so
`desired_tag_values` omits its `active` tag and the reconciliation step
deletes the stale binding from the VM.

Rules in the shared policy for that firewall remain until
`VpcUpdateFirewallRules#cleanup_orphaned_firewall_rules` (run at the
tail of the VPC's `update_firewall_rules` label) drops them. Orphan
detection is based on whether any VM in the VPC still has the firewall
in its effective set, with a defensive UNION over
`firewalls_private_subnets` and `firewalls_vms` to guard against a
firewall attached in another VPC.

### Editing a firewall's rules

`FirewallRule` insertion/deletion calls
`Firewall#update_private_subnet_firewall_rules`, which bumps
`update_firewall_rules` on each attached subnet. On GCP,
`SubnetNexus#wait` propagates that bump to the subnet's `gcp_vpc` only
(no per-VM fan-out for rule edits, since tag bindings don't change). On
metal/AWS the same subnet-level bump fans out to VMs (no VPC consumer).
The VPC's `VpcUpdateFirewallRules` calls `sync_firewall_rules(fw.rules,
tag_value_name)`, which content-diffs desired vs. existing policy rules
and applies the minimum edits. Priority numbers may shift; semantics
don't, because evaluation is by `(target_tag, src_ip, layer4_configs)`,
not by priority.

### VM destroy

When a VM is deleted, GCE removes its tag bindings along with the
instance. If `UpdateFirewallRules` happens to be queued or running at
that moment, `before_run` checks `vm.destroy_set?` and `pop`s without
trying to mutate tags (per-VM tag bindings are gone with the instance
anyway). Cleanup of now-unused policy rules, tag values, and tag keys
for firewalls that have no remaining references runs opportunistically
inside `VpcUpdateFirewallRules#cleanup_orphaned_firewall_rules` the next
time a rule edit or attach lands on this VPC.

## Sharp Edges

### 10-tag VM binding limit

GCE enforces a hard cap of 10 tag bindings per VM (Compute instance),
checked at request time during `create_tag_binding`. A VM needs:

- 1 binding for `ubicloud-subnet-{s.ubid}/active`
- 1 binding per firewall in its effective set

So a VM can belong to at most **9 firewalls**. The cap is enforced
upstream by `Firewall.validate_gcp_firewall_cap!`, which fires from
`Firewall#associate_with_private_subnet` and from the `before_add` hook
on `vm.vm_firewalls`. Crossing the cap raises
`Validation::ValidationFailed` at the model layer, before any GCP
request goes out.

`UpdateFirewallRules#update_firewall_rules` defends against an upstream
regression by raising loudly if `desired_tag_values.size >
GCP_MAX_TAGS_PER_VM`, which would only fire if the cap validation chain
were broken.

### Tag-binding reconciliation

`update_firewall_rules` maintains the VM's binding set in three steps:

1. **Build the desired set** (firewall tags from `vm.firewalls` whose
   firewall has any rules, plus the subnet `active` tag).
2. **Attempt every desired binding unconditionally.** The code does not
   pre-diff against `list_tag_bindings`: the read-side list view is
   eventually consistent against an independent replica from the write
   side, so trusting it to skip "already-bound" entries can mask a
   binding that hasn't durably committed. `create_tag_binding` returns
   200 (just created) or 409 (already exists) - both idempotent. On 400
   or 403 the parent VM resource or tag value hasn't yet propagated to
   the zonal CRM endpoint (capacity is ruled out by the cap validation
   above): nap and let the next strand iteration retry.
3. **Fire-and-forget stale deletes.** After all desired bindings are
   confirmed, list existing bindings and delete any not in the desired
   set, swallowing 404 (already gone). Stale-binding cleanup is allowed
   to use the list because a transiently-stale list entry only causes a
   skipped delete that a subsequent run will catch - harmless, unlike
   skipping a create.

### Idempotent restart of firewall sync

`VpcUpdateFirewallRules` runs once per VPC, so its tag-key/value/rule
writes are not racing other Ubicloud strands. The idempotency rescues
exist for **strand-restart**: a prior label invocation's CRM LRO may
have actually committed before the strand crashed or the runtime
restarted, so the retry attempt can see HTTP 409 (`AlreadyExistsError`)
or operation status code 6 (`ALREADY_EXISTS`). `ensure_firewall_tag_key`
and `ensure_tag_value` catch both and fall through to a list-based
lookup to return the already-created name. `create_tag_policy_rule`
applies the same idea for `InvalidArgumentError: same priorities`:
re-read the policy, pick a new free slot past the colliding priority,
and retry (up to 5 attempts) - per the code comment, this guards the
edge case where a prior subnet `add_rule` LRO is still in flight when we
read the policy.

### Orphan cleanup

`VpcUpdateFirewallRules#cleanup_orphaned_firewall_rules` (run at the
tail of the VPC's `update_firewall_rules` label) lists the VPC's
firewall tag keys (filtered to `purpose == GCE_FIREWALL` scoped to this
VPC's network), pairs each with its firewall UUID, and excludes any that
are still referenced by `firewalls_private_subnets` or `firewalls_vms`
in the DB. For each orphaned firewall, it deletes the policy rules
targeting that firewall's `active` tag value, then deletes the tag value
and tag key.


### Operation polling for tag-binding writes (durability vs HTTP 200)

Compute instances are zonal, so the Tag Binding API requires the zonal
CRM endpoint (e.g. `us-central1-a-cloudresourcemanager.googleapis.com`).
Despite the method name `regional_crm_client`, callers from
`UpdateFirewallRules` pass the zone (`us-central1-a`) rather than the
region. The zonal endpoint implements a write-buffering pattern that
splits "accept" from "durably committed":

1. `create_tag_binding` to the zonal endpoint returns HTTP 200 once the
   zonal shard buffers the write to its local replica.
2. Asynchronously, the zonal shard validates parent visibility (the VM
   instance) and tag-value visibility against **global** CRM. If either
   hasn't propagated yet, the zonal shard rolls back the buffered write.
3. The Long-Running Operation (LRO) returned alongside the HTTP 200 only
   transitions to `done?: true` once durability is confirmed. If the
   write was rolled back, the LRO completes with `error` set.

The HTTP 200 alone is therefore NOT proof of durability. A binding can
appear in `list_tag_bindings` briefly and then disappear. This shows up
in practice as: a freshly-provisioned VM has all its expected tag
bindings according to the CRM accept response, but the VPC firewall data
plane never gets the bindings, so traffic stays blocked even though the
strand believes it succeeded.

**Required pattern for any tag-binding mutation:**

```ruby
op = regional_crm_client.create_tag_binding(...)
until op.done?
  sleep 1
  op = regional_crm_client.get_operation(op.name)
end
raise CrmOperationError.new(op.name, op.error) if op.error
```

Rules of thumb:

- **Treat zonal-CRM operations as authoritative only after `op.done?`
  and `op.error.nil?`** - never after just the initial HTTP response.
- `code: 6` (`ALREADY_EXISTS`) on the operation is the durable
  equivalent of HTTP 409 - swallow as idempotent success.
- For other CRM operations that already use frame-tracked LRO polling
  (e.g. `ensure_firewall_tag_key`, `ensure_tag_value`), keep that
  pattern; it's the same contract, just preserved across naps via the
  strand stack.
- Synchronous `sleep 1` polling is acceptable for tag bindings because
  individual binding ops complete in milliseconds-to-seconds. For any
  CRM operation that can take longer (tag-key/value creation), use the
  frame-tracked nap-poll pattern in `vpc_update_firewall_rules.rb`
  instead so the strand thread isn't held for the duration.

This polling contract applies to **every** GCP API that returns an LRO,
not just CRM. Compute Engine LROs (instance create/delete, subnet
create/delete, address allocate/release, VPC create/delete,
firewall-policy add/delete, association add/remove) should be polled
the same way before treating the call as complete. The `gcp_lro.rb`
module provides a shared `save_gcp_op` / `poll_and_clear_gcp_op` helper
that frame-tracks operation names across naps for the long-running
cases.

### Public-internet INGRESS is not blocked by default

The Layer 1 DENY rules only cover RFC 1918 and GCE internal IPv6. A VM
with a public IPv4 (assigned via `AssignedVmAddress`) receives
public-internet traffic unless explicitly blocked by a firewall rule at
a lower priority number. This matches AWS Security Group semantics
(explicit ALLOW, implicit block when the policy evaluation falls through
with no match; GCP Network Firewall Policies then defer to the
next-lower policy in the chain or the default VPC firewall).

If stronger isolation is needed, add a `FirewallRule` with the desired
source CIDR and **no** matching port to force explicit coverage, or add
a VPC-wide INGRESS DENY rule for `0.0.0.0/0` and `::/0` at the tail of
Layer 1 (not done currently).

## Priority Allocation Mechanics (summary)

### Subnet priorities (DB-backed)

Stored in `private_subnet.firewall_priority`. Allocation is optimistic:

1. Query all used priorities for the same `(project, location)`,
   excluding this subnet.
2. Find the first free even number in 1000..8998.
3. `UPDATE private_subnet SET firewall_priority = ?`.

The partial unique index
`private_subnet_project_location_firewall_priority_idx` enforces
uniqueness; on a concurrent collision the losing `UPDATE` raises
`Sequel::UniqueConstraintViolation` and aborts the strand label. The
strand machinery re-runs the label, which re-scans against the
now-updated used set and picks a different slot.

### Per-firewall rule priorities (policy-backed)

Not stored in the DB. `VpcUpdateFirewallRules#sync_tag_policy_rules`
reads the current policy on every sync, finds all used priorities, and
picks free slots starting from 10000. Content-based diffing (ignoring
priority) ensures rules are only created/deleted when their actual
content changes.

## Implementation Files

| File | Responsibility |
|------|---------------|
| `prog/vnet/gcp/vpc_nexus.rb` | VPC + firewall policy lifecycle, VPC-wide DENY rules, tag key/value deletion at destroy |
| `prog/vnet/gcp/subnet_nexus.rb` | Subnet, subnet tag key/value, subnet allow rules, priority allocation |
| `prog/vnet/gcp/vpc_update_firewall_rules.rb` | Per-firewall tag key/value, INGRESS policy rules, orphan cleanup (VPC-scoped, runs once per VPC) |
| `prog/vnet/gcp/update_firewall_rules.rb` | Per-VM tag binding reconciliation |
| `prog/vnet/gcp/nic_nexus.rb` | NIC lifecycle, static IP allocation (no firewall responsibility) |
| `model/firewall.rb` | `associate_with_private_subnet`, per-VM cap validation (`validate_gcp_firewall_cap!`) |
| `model/vm.rb` | `vm.firewalls = private_subnet_firewalls + vm_firewalls` |
