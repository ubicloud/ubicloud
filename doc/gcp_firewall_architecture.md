# GCP Network Firewall Architecture

## Overview

Ubicloud uses [GCP Network Firewall Policies](https://cloud.google.com/firewall/docs/network-firewall-policies)
to implement per-VM firewalls on GCP. A single firewall policy is attached to each
VPC and contains all rules for all subnets and VMs in that VPC. Rules are
differentiated using **GCP Secure Tags** — each rule targets a specific tag value,
and only VMs bound to that tag value are affected.

GCP firewall policies have a flat priority space (0–65535) where **lower number =
higher precedence**. We partition this space into three bands.

## Priority Bands

```
Priority Range   Band                  Purpose
──────────────   ────────────────────  ──────────────────────────────
1000 – 8999      Subnet ALLOW EGRESS   Intra-subnet traffic for tagged VMs
10000 – 59999    Per-VM INGRESS        Tag-targeted allow rules per firewall
65531 – 65534    VPC-wide DENY         Block all private traffic by default
```

### Layer 1: VPC-wide DENY (priorities 65531–65534)

Created by `SubnetNexus#create_vpc_deny_rules`. Four rules block all RFC 1918 and
GCE internal IPv6 traffic (both INGRESS and EGRESS) for **every VM** in the VPC.
No tags — these are unconditional.

This establishes a default-deny posture: no private traffic flows unless explicitly
allowed by a higher-precedence (lower-numbered) rule.

| Priority | Direction | IP Ranges |
|----------|-----------|-----------|
| 65534    | INGRESS   | RFC 1918 (10/8, 172.16/12, 192.168/16) |
| 65533    | EGRESS    | RFC 1918 |
| 65532    | INGRESS   | GCE internal IPv6 (fd20::/20) |
| 65531    | EGRESS    | GCE internal IPv6 |

### Layer 2: Subnet ALLOW EGRESS (priorities 1000–8998)

Created by `SubnetNexus#create_subnet_allow_rules`. Each `PrivateSubnet` gets an
allocated **even** priority P in the range 1000–8998. Two rules are created:

| Priority | Direction | Target | Effect |
|----------|-----------|--------|--------|
| P        | EGRESS    | Subnet's secure tag value | Allow IPv4 egress to subnet CIDR |
| P+1      | EGRESS    | Subnet's secure tag value | Allow IPv6 egress to subnet CIDR |

These override the VPC-wide DENY rules (lower priority number = higher precedence)
but **only for VMs tagged as members of this subnet**.

**Tag structure**: Each subnet has a tag key (`ubicloud-subnet-{subnet.ubid}`) with
a tag value `"member"`. When a VM is provisioned in this subnet, `UpdateFirewallRules`
binds the VM's NIC to this tag value.

**Priority allocation** (`SubnetNexus#allocate_subnet_firewall_priority`): Scans
existing priorities for the same (project, location) pair, finds the first unused
even number in 1000..8998, and atomically claims it via a DB unique constraint. With
4000 even slots (1000, 1002, 1004, ..., 8998), up to **4000 subnets per project per
location** are supported.

The priority is stored on the `private_subnet` table with a CHECK constraint ensuring
values are even numbers in the valid range: `firewall_priority % 2 = 0 AND
firewall_priority BETWEEN 1000 AND 8998`.

### Layer 3: Per-VM INGRESS (priorities 10000+)

Created by `UpdateFirewallRules#sync_firewall_rules`. Each Ubicloud **Firewall**
object gets its own GCP secure tag resources and INGRESS rules.

**Tag structure per firewall**:
1. **Tag key**: `ubicloud-fw-{firewall.ubid}` (with `GCE_FIREWALL` purpose, scoped to the VPC)
2. **Tag value**: `"active"` under that key

**Policy rules** are created at priorities starting from 10000. Each rule targets
the firewall's tag value and allows specific INGRESS traffic (protocol + port range
from a source CIDR).

**VM binding**: When `UpdateFirewallRules` runs for a VM, it binds the VM's NIC to
each active firewall's `"active"` tag value. This is how a VM "subscribes" to a
firewall's rules.

## Concrete Example

VPC `ubicloud-pj0abc...` with two subnets and three VMs:

```
Subnet A (priority 1000, tag: ubicloud-subnet-ps111/member)
├── VM1 — Firewall F1 (tag: ubicloud-fw-fw111/active)
│         Rules: allow TCP 5432, allow TCP 22
└── VM2 — Firewall F1 + Firewall F2 (tag: ubicloud-fw-fw222/active)
          F2 rules: allow TCP 443

Subnet B (priority 1002, tag: ubicloud-subnet-ps222/member)
└── VM3 — Firewall F3 (tag: ubicloud-fw-fw333/active)
          Rules: allow TCP 8080, allow TCP 22
```

### Resulting firewall policy rules

```
Priority  Dir     Action  Target Tag                    What it does
────────  ──────  ──────  ──────────────────────────    ─────────────────────
1000      EGRESS  ALLOW   ubicloud-subnet-ps111/member  Subnet A IPv4 egress
1001      EGRESS  ALLOW   ubicloud-subnet-ps111/member  Subnet A IPv6 egress
1002      EGRESS  ALLOW   ubicloud-subnet-ps222/member  Subnet B IPv4 egress
1003      EGRESS  ALLOW   ubicloud-subnet-ps222/member  Subnet B IPv6 egress
10000     INGRESS ALLOW   ubicloud-fw-fw111/active      F1: TCP 5432 from ...
10001     INGRESS ALLOW   ubicloud-fw-fw111/active      F1: TCP 22 from ...
10002     INGRESS ALLOW   ubicloud-fw-fw222/active      F2: TCP 443 from ...
10003     INGRESS ALLOW   ubicloud-fw-fw333/active      F3: TCP 8080 from ...
10004     INGRESS ALLOW   ubicloud-fw-fw333/active      F3: TCP 22 from ...
65531     EGRESS  DENY    (all VMs)                     Block private IPv6
65532     INGRESS DENY    (all VMs)                     Block private IPv6
65533     EGRESS  DENY    (all VMs)                     Block private IPv4
65534     INGRESS DENY    (all VMs)                     Block private IPv4
```

### Tag bindings per VM NIC

| VM  | Tag Bindings |
|-----|-------------|
| VM1 | `ubicloud-subnet-ps111/member`, `ubicloud-fw-fw111/active` |
| VM2 | `ubicloud-subnet-ps111/member`, `ubicloud-fw-fw111/active`, `ubicloud-fw-fw222/active` |
| VM3 | `ubicloud-subnet-ps222/member`, `ubicloud-fw-fw333/active` |

### How GCP evaluates rules

**VM1 receives inbound TCP 5432:**
1. Priority 1000 — EGRESS → skip (wrong direction)
2. Priority 10000 — INGRESS ALLOW for `ubicloud-fw-fw111/active` — VM1 has this tag → **ALLOW**

**VM3 receives inbound TCP 443:**
1. Priority 10003, 10004 — target `ubicloud-fw-fw333/active` — neither allows 443
2. Priority 65534 — INGRESS DENY all → **DENY**

### Why priorities can overlap across firewalls

F1 and F3 both have rules at priority 10000. This works because they target
**different tags**. A rule only evaluates for VMs bound to its target tag. F1's rule
at 10000 never affects VM3 (no `fw111` tag), and F3's rule at 10003 never affects
VM1/VM2 (no `fw333` tag).

## Tag Limits

GCP allows **max 10 tag bindings per NIC**. A VM needs 1 binding for its subnet tag
plus 1 per firewall, so a VM can belong to at most **9 firewalls**. If exceeded,
`UpdateFirewallRules` truncates (keeping the subnet tag) and logs a warning.

A model-level validation that refuses to attach a 10th firewall to a GCP VM is
tracked as a follow-up so the truncation path becomes a defensive backstop
rather than the primary guardrail.

## Priority Allocation Mechanics

### Subnet priorities (DB-backed)

Stored in `private_subnet.firewall_priority`. Allocation uses optimistic locking:

1. Query all used priorities for the same (project, location)
2. Find the first free even number in 1000..8998
3. `UPDATE private_subnet SET firewall_priority = ?`
4. If a `UniqueConstraintViolation` occurs (concurrent allocation), retry up to 5 times

### Per-VM rule priorities (policy-backed)

Not stored in the DB. `UpdateFirewallRules#sync_tag_policy_rules` reads the current
policy, finds all used priorities, and picks free slots starting from 10000. Content-
based diffing (ignoring priority) ensures rules are only created/deleted when their
actual content changes, not when priorities shift.

## Implementation Files

| File | Responsibility |
|------|---------------|
| `prog/vnet/gcp/subnet_nexus.rb` | VPC, subnet, deny rules, subnet allow rules, priority allocation |
| `prog/vnet/gcp/update_firewall_rules.rb` | Per-VM firewall tags, INGRESS rules, tag bindings, cleanup |
| `prog/vnet/gcp/nic_nexus.rb` | NIC lifecycle, static IP allocation (not firewall-related) |
