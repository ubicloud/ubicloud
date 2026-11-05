# Terraform provider generator: design

The generator turns `openapi/openapi.yml` into the Ubicloud terraform provider. This document
describes its design, and later changes to the generator should keep to it. The decisions behind
the design are in `doc/terraform-generator-brief.md`. The prototype in pull request 6331 was used
as a reference, not as a base.

In short, a pure Ruby derivation reads the spec and a short definitions file, and produces one
record per terraform type. One renderer writes each record as a Go file of builder calls, one call
per fact, each with a comment naming the rule and the spec location it came from. A hand-written
Go engine interprets those files: the engine holds all the control flow, and the generated files
hold none. The generated files are not committed. `rake terraform:generate` writes them into the
working tree, where an engineer may edit them before carrying the edit back into the generator.

The generator is a separate program, in the top-level directory `terraform/`, which clover never
loads. The harness that tests the provider against clover's API in process is designed in
`doc/terraform-harness-design.md`, and the API versions, deprecated names and norms that the spec
changes rely on in `doc/api-versions-design.md`.

## 1. Where each fact lives

Every fact the API states for every client belongs in the spec. A definition holds only what the
spec cannot state, and the runtime holds only terraform policy.

| Fact | Where it lives |
|---|---|
| attributes, names, types | the spec: path parameters, request bodies, response schemas |
| required, optional, computed | the spec: `required`, which bodies carry a property, `readOnly` |
| write-only, sensitive, default | the spec: `writeOnly`, `format: password`, `default` |
| validators | the spec: `enum`, `pattern`, `minimum`, `maximum`, `minLength`, `maxLength` |
| descriptions and examples | the spec: `description`, `example` |
| replace on change | a rule: a create input that no update verb carries |
| update verbs | a rule over the item path and its subroutes |
| which state values mean "still working" or "failed" | the spec: `x-lifecycle` on the state property |
| outputs that never change once known | the spec: `x-immutable` |
| refusals worth retrying | the spec: a `Retry-After` header on the refusal |
| a deprecated request name, what replaces it, and the API version that refuses it | the spec: `x-deprecated` |
| the create's idempotency key | a rule: the name, for a named type (§4.1) |
| identity, parent keys, import id | a rule over the item path's parameters |
| which types the provider offers | the definitions file |
| the order of update verbs, where it matters | the definitions file (`order:`) |
| timeouts, poll interval, terraform version | the runtime, one policy for every type |

`x-lifecycle` and `x-immutable` are new vendor extensions, which `openapi/README.md` defines beside
the deprecation extensions of `doc/api-versions-design.md`. Both state facts about the API that
other clients could use too, such as the web UI's auto-refresh or a `--wait` option in the CLI.
Adding them needs no change to the tooling: the linters already accept the spec's `x-go-name`
keys, and openapi_parser ignores `x-` keys.

## 2. The pipeline

```
definitions.rb ──────────────┐
openapi.yml ─Api.load─▶ Api ─┴─Derive─▶ [Type] ─Go, Hcl─▶ {path => text} ─Tree─▶ terraform/provider/
                             rules §4, invariants §4.7                           statuses, stamps
```

| Stage | Input | Output | File |
|---|---|---|---|
| Load | `openapi/openapi.yml`, by absolute path | `Api`: `$ref` resolved, `allOf` merged, item paths indexed by type name | `terraform/lib/terraform_generator/api.rb` |
| Define | the definitions file | `Definitions::TYPES`, a frozen Hash, its keys validated | `terraform/lib/terraform_generator/definitions.rb` |
| Derive | `Api` and one definition | a `Type` record, or `SpecError` naming the spec location and the fix | `terraform/lib/terraform_generator/derive.rb` |
| Emit | the `Type` records | `{module-relative path => text}` | `terraform/lib/terraform_generator/go.rb`, `hcl.rb` |
| Sync | the rendered files and the module on disk | a status per file; writes for `generate` | `terraform/lib/terraform_generator/tree.rb` |

Clover never loads the generator, in production or in its main test suite, since nothing in it
runs while clover serves requests. Like the kubernetes CSI driver, it is a program alongside clover
rather than part of it. Its parts live in `terraform/`:

| Directory | Holds |
|---|---|
| `terraform/lib/` | the generator: plain Ruby that needs only the standard library and `openapi/norms.rb`, run under clover's bundle |
| `terraform/spec/` | the generator's specs, with their own `spec_helper.rb` and coverage (§8.1) |
| `terraform/provider/` | the Go module: the hand-written engine (§7), and the generated files, which git ignores |

The harness is the one part tied to clover's test infrastructure, so it lives in clover's
`spec/terraform/` (§8.2). The generator does not boot the app, open the database, or read the
working directory. Everything that runs `go` or `terraform` is a rake task in the `Rakefile`'s
`terraform` namespace, the engineer's entry point. Clover's `spec/coverage_helper.rb` skips
`terraform/`, whose files the main suite never loads.

The model passes between stages as `Data` records, frozen at birth:

```ruby
# frozen_string_literal: true

module TerraformGenerator
  SPEC = File.expand_path("../../openapi/openapi.yml", __dir__)
  MODULE = File.expand_path("../provider", __dir__)
  SpecError = Class.new(StandardError)

  # One terraform type: its name, its item path in attribute names, its description, and its
  # statements; and, for the examples (§6.8), each attribute's example value, the attributes a
  # resource's example sets, and, for each of those that holds another type's id, that type's name.
  Type = Data.define(:name, :item, :doc, :statements, :examples, :example_inputs, :references, :why)

  # Each statement renders as one builder call in the generated Go: the call is named after the
  # record's class, its members other than `why` are the arguments in order, a nil member is
  # left out, and an Array in the last place is spread. `why`, a list of [rule, source] pairs,
  # becomes the comment above the call.
  Create = Data.define(:method, :path, :body, :why)
  Datasource = Data.define(:lookup, :why)
  Pending = Data.define(:attr, :values, :why)
  Failed = Data.define(:attr, :values, :why)
  Attr = Data.define(:name, :type, :flags, :doc, :default, :checks, :why)
  Verb = Data.define(:method, :path, :body, :why)
  Dropped = Data.define(:operation, :why)   # a comment only: a candidate verb a rule set aside

  Call = Data.define(:name, :args)           # a Go call inside an argument: listOf(...), oneOf(...)
  Nested = Data.define(:kind, :var, :attrs, :why)  # an object type; kind is :single, :list or :set

  def self.types(api = Api.load, definitions = Definitions::TYPES) =
    definitions.map { |name, facts| Derive.new(api, name, facts).type }

  # Hcl takes every type at once, because one type's example can include another's.
  def self.files(api = Api.load, definitions = Definitions::TYPES)
    types = types(api, definitions)
    [*types.map { Go.file(it) }, *Hcl.files(types)].to_h
  end
end
```

The rake tasks hand `files` to `Tree` (§6.6). Its `write` writes them and returns each file's
status, and its `edits` gives each edited file with the text that `rake terraform:diff` compares
it with.

The Ruby records mirror the Go builder calls member for member, so the renderer needs no table of
names: `Attr` becomes `t.attr(...)`, `Verb` becomes `t.verb(...)`, and adding a statement kind
takes only a new record and a new builder function.

With the fourteen types of the first cut defined, the Ruby comes to about 910 lines. `derive.rb`
has 510 of them; `api.rb`, `tree.rb`, `terraform_generator.rb`, `hcl.rb` and `go.rb` have 50 to
90 each; and `definitions.rb` has 27.

## 3. Definitions

### 3.1 The file

```ruby
# frozen_string_literal: true

# The terraform types the provider offers. Everything about them is derived from
# openapi/openapi.yml; an entry states only the order of update verbs, where that order matters.
module TerraformGenerator::Definitions
  TYPES = {
    firewall: {},
    firewall_rule: {},
    inference_api_key: {},
    kubernetes_cluster: {},
    kubernetes_cluster_nodepool: {},
    load_balancer: {},
    postgres: {order: %i[upgrade]},
    postgres_firewall_rule: {},
    postgres_log_destination: {},
    postgres_metric_destination: {},
    private_subnet: {},
    project: {},
    ssh_public_key: {},
    vm: {},
  }.freeze

  # The keys an entry may have. order names verbs that run before the
  # others, in that order.
  KEYS = %i[order].freeze
end
```

Every entry has one shape: a type name, and a Hash whose keys come from a closed set. The set has
one key, `order`, which names verbs that run before the others, in that order. Derivation refuses an
unknown key, a name that no item path derives (listing the nearest names), and an `order` that
names no verb of the type.

`order` has one user. A postgres upgrade is refused once a resize has started a convergence
(`Validation.validate_postgres_upgrade`), and the resize does not check for an upgrade, so when one
apply changes both, the upgrade must go first. The API could make the key unnecessary by folding
every postgres verb into its PATCH and ordering the changes in the server, but for now that is more
API work than one counted special case (§6.7) is worth.

Datasources, waits, retries, stability, idempotency and timeouts are not definition facts. The
first five come from a rule or from the spec, and timeouts are one runtime policy for every type.

### 3.2 The first cut, type by type

The first cut is these fourteen types; kubernetes rests on C36, and the metric destination on
C29. Abbreviations: R required, O optional, C computed, D default from the spec, WO write-only,
S sensitive, X replace on change, st stable (kept in plans), set and map for collection types.
The change ids C1 to C38 are listed in §5. Attribute names are the spec's, except those that rule
`ids` gives; there are no other renames.

**project** (`project: {}`)

| | Derived |
|---|---|
| kinds | datasource only: there is no create |
| lookup | none: `{project_id}` is the provider's (rule `scope`), so the datasource reads the provider's project |
| outputs | `id`, `name` |
| needs | C17 |

**ssh_public_key** (`ssh_public_key: {}`)

| | Derived |
|---|---|
| create | `registerSshPublicKey`, on the collection, body `{name, public_key}` |
| inputs | `name` R, `public_key` R; both updated in place by `updateSshPublicKey`, the POST on the item (clause `item_post_verb`) |
| outputs | `id` st |
| datasource | by `id` or `name` |
| import | `<id or name>` |
| needs | C3, C17 |

**inference_api_key** (`inference_api_key: {}`)

| | Derived |
|---|---|
| create | `createInferenceApiKey`, on the collection, empty body |
| outputs | `id` st; `key` S st (`format: password`, `x-immutable`) |
| datasource | by `id`; `key` stays sensitive |
| import | `<id>` |
| needs | C17 |

**firewall** (`firewall: {}`)

| | Derived |
|---|---|
| create | `createLocationFirewall`, on the item, body `{description}` |
| keys | `location` R X; `name` R, renamed by `renameFirewall` |
| inputs | `description` O C D `""`, updated by `updateFirewall` |
| outputs | `id` st; `path`; `firewall_rule_ids` and `private_subnet_ids` (rule `ids`) |
| not verbs | attach-subnet and detach-subnet: their bodies carry no firewall attribute |
| datasource | by `id` or `name` |
| import | `<location>/<id or name>` |
| needs | C7, C12, C18 |

**firewall_rule** (`firewall_rule: {}`)

| | Derived |
|---|---|
| create | `createLocationFirewallRule`, on the collection; its response `FirewallRuleOrRules` is a union containing the rule (clause `union_collapse`) |
| keys | `location` R X; `firewall_id` R X, with `Firewall.id`'s pattern |
| inputs | `cidr` R (format `cidr`); `port_range` O C D `0..65535` (format `port-range`); `protocol` O C D `tcp`, one of tcp and udp (the response's enum); `description` O C D `""`; all updated by `modifyFirewallRule` |
| outputs | `id` st |
| datasource | by `location`, `firewall_id`, and `id` |
| import | `<location>/<firewall_id>/<id>` |
| needs | C2, C3, C14, C18 |

The `cidr` format refuses a private subnet's name or id at plan time, so the create response is
always one rule, never the array a subnet reference expands to.

**private_subnet** (`private_subnet: {}`)

| | Derived |
|---|---|
| create | `createPrivateSubnet`, on the item, body `{firewall_id}` |
| keys | `location` R X; `name` R, renamed by `renamePrivateSubnet` |
| inputs | `firewall_id` O WO X |
| outputs | `id` st; `net4`, `net6` st (`x-immutable`); `state`; `firewall_ids`; `nics` nested |
| waits | settles while `state` is `creating`, `refreshing_keys` or `deleting`; delete waits for 404 |
| not verbs | connect (its body carries no subnet attribute) and disconnect (no body) |
| datasource | by `id` or `name` |
| needs | C18 |

**load_balancer** (`load_balancer: {}`)

| | Derived |
|---|---|
| create | `createLocationLoadBalancer`, on the item |
| keys | `location` R X; `name` R, renamed by `renameLoadBalancer` |
| inputs updated by `patchLocationLoadBalancer` | `algorithm` R, `dst_port` R, `src_port` R, `health_check_endpoint` O C D `/up`, `cert_enabled` O C, `vms` O C set (not in the create body, so the PATCH runs right after create when `vms` is configured) |
| inputs that replace | `health_check_protocol` R X, `private_subnet_id` R X, `stack` O C D `dual` X |
| outputs | `id` st; `hostname` (it contains the name, so it moves on rename); `subnet` |
| dropped | `toggleSslCertificateLoadBalancer`: the PATCH already owns `cert_enabled` (rule `verb_owner`) |
| not verbs | attach-vm and detach-vm: their bodies carry no load balancer attribute |
| waits | delete waits for 404 |
| datasource | by `id` or `name` |
| needs | C6, C8, C12, C13, C15, C18 |

**vm** (`vm: {}`)

| | Derived |
|---|---|
| create | `createVM`, on the item |
| keys | `location` R X; `name` R, renamed by `renameVM` |
| inputs that replace | `public_key` R WO X; `init_script` O WO S X; `boot_image` O C X; `ip4_enabled` O C D `false` X; `private_subnet_id` O C X; `size` O C D `standard-2` X; `storage_size` O C X; `gpu_count`, `gpu_device` O C X; `unix_user` O C D `ubi` X |
| inputs updated in place | `maintenance_window_start_at` O, 0 to 23, null to clear, by `setVMMaintenanceWindow`, which runs right after create when it is configured |
| outputs | `id` st; `state`; `ip4`, `ip6`, `private_ipv4`, `private_ipv6`, `storage_size_gib` st (`x-immutable`); `firewall_ids`; `subnet`; `gpu` |
| waits | settles while `state` is `creating`, `starting`, `rebooting`, `restarting`, `stopping`, `waiting for capacity` or `deleting`; fails on `no capacity available`; delete waits for 404 |
| not verbs | restart, start and stop have no body |
| datasource | by `id` or `name` |
| needs | C6, C9, C15, C16, C19 |

A stopped or unavailable VM is not pending, so a rename of one returns at once.

**postgres** (`postgres: {order: %i[upgrade]}`)

| | Derived |
|---|---|
| create | `createPostgresDatabase`, on the item |
| keys | `location` R X; `name` R, renamed by `renamePostgres` |
| inputs | `size` R, `storage_size` R, `ha_type` O C D `none`, `tags` O C (all by `patchPostgresDatabase`); `target_version` O C (by `upgradePostgresDatabase`); `pg_config`, `pgbouncer_config` O C map of string (by `updatePostgresDatabaseConfig`); `maintenance_window_start_at` O, null to clear, `maintenance_window_days` O C (by `setMaintenanceWindow`); `password` O C S (by `resetSuperuserPassword`) |
| inputs that replace | `restrict_by_default` O C WO D `false` X; `private_subnet_name` O WO X |
| outputs | `id` st; `state`; the observed `vm_size`, `storage_size_gib`, `version`; the converging `target_vm_size`, `target_storage_size_gib`; `hostname`, `connection_string` S, `private_connection_string` S, `ca_certificates`, `primary`, `fallback_active`, `read_replica`, `parent`, `earliest_restore_time`, `target_server_count`, `username`; `private_subnet_id`, `created_at` st; `firewall_id`, null once that firewall is deleted, renamed or detached from the subnet; `firewall_rule_ids`, `log_destination_ids`, `metric_destination_ids`, `read_replica_ids` |
| verbs, in order | upgrade (the definition), PATCH, config, rename, reset-superuser-password, set-maintenance-window |
| not verbs | `patchPostgresDatabaseConfig` (clause `merge_subroute`); read-replica and restore (clause `name_carrier`); restart, recycle and promote have no body; `cert/*` are not direct subroutes |
| waits | settles while `state` is `creating`, `restoring_backup`, `replaying_wal`, `finalizing_restore`, `restarting` or `deleting`; delete waits for 404 |
| datasource | by `id` or `name` |
| needs | C6, C10, C20 to C25 |

`size` and `storage_size` hold what the user last asked for. C21 keeps them apart from the targets,
which storage auto-scale may raise. A PATCH that changes only `ha_type` resends them unchanged, so
the server leaves an auto-scaled target alone. A resize leaves `state` at `running` until the
maintenance window, so the settle after the PATCH returns at once. That is right for a verb that
only records the desired state.

**postgres_firewall_rule** (`postgres_firewall_rule: {}`)

| | Derived |
|---|---|
| create | `createLocationPostgresFirewallRule`, on the collection |
| keys | `location` R X; `postgres_id` R X, with `PostgresDatabase.id`'s pattern |
| inputs | `cidr` R (format `cidr`); `description` O C D `""`; both by `patchLocationPostgresFirewallRule` |
| outputs | `id` st; not `port`, which C27 deprecates |
| datasource | by `location`, `postgres_id`, and `id` |
| import | `<location>/<postgres_id>/<id>` |
| needs | C26, C27, C28 |

This type must not ship before C27. Without it, a destroy leaves the pgbouncer port open, and every
later create of the same CIDR fails on the leftover 6432 rule.

**postgres_log_destination** (`postgres_log_destination: {}`)

| | Derived |
|---|---|
| create | `createLocationPostgresLogDestination`, on the collection |
| keys | `location` R X; `postgres_id` R X |
| inputs, all X | `name` R; `type` R, one of otlp and syslog; `url` R; `options` O WO S, an object with `headers` (map of string) and `structured_data` (map of map of string) |
| outputs | `id` st |
| datasource | by `location`, `postgres_id`, and `id` |
| needs | C26, C28 |

**postgres_metric_destination** (`postgres_metric_destination: {}`)

| | Derived |
|---|---|
| create | `createLocationPostgresMetricDestination`, on the collection |
| keys | `location` R X; `postgres_id` R X |
| inputs, all X | `url` R; `username` O; `password` O WO S; `options` O WO S |
| outputs | `id` st; `auth_methods` |
| datasource | by `location`, `postgres_id`, and `id` |
| needs | C26, C28, C29 |

Until C29 the create returns the parent database, from which the new destination's id cannot be
known, and invariant `create_response` refuses the type.

**kubernetes_cluster** (`kubernetes_cluster: {}`)

| | Derived |
|---|---|
| create | `createKubernetesCluster`, on the item, after C36 without a default nodepool |
| keys | `location` R X; `name` R, at most 37 characters at create, renamed by `renameKubernetesCluster` |
| inputs | `version` R, by `upgradeKubernetesCluster`; `cp_node_count` O C D `1`, one of 1 and 3, X |
| outputs | `id` st; `state`; `node_size` st (`x-immutable`); `services_load_balancer_url`; `cp_vm_ids`, `nodepool_ids` |
| waits | settles while `state` is `creating`, `upgrading` or `deleting`; delete waits for 404 |
| datasource | by `id` or `name` |
| needs | C4, C6, C31, C33 to C37 |

**kubernetes_cluster_nodepool** (`kubernetes_cluster_nodepool: {}`)

| | Derived |
|---|---|
| create | `createKubernetesNodepool`, on the collection |
| keys | `location` R X; `kubernetes_cluster_id` R X, merged with the response property of that name |
| inputs | `name` R (`renameKubernetesNodepool`); `node_count` R, at least 1 (`resizeKubernetesNodepool`); `version` O C (`upgradeKubernetesNodepool`); `node_size` R X |
| outputs | `id` st; `state`; `vm_ids` |
| waits | settles while `state` is `creating`, `resizing`, `upgrading` or `deleting`; delete waits for 404 |
| datasource | by `location`, `kubernetes_cluster_id`, and `id` or `name` |
| needs | C4, C32 to C34, C37 |

When nodepools of one cluster are applied in parallel, the cluster's `idle?` check refuses a
nodepool create or resize while another nodepool is still changing. C34 makes those refusals carry
`Retry-After`, and rule `retry` repeats them, creates included, so the runtime needs no lock per
cluster. The derived name keeps both nouns, as Azure's provider does; a definition word to shorten
it would be a special case for one type.

### 3.3 Deferred, and what brings each in

| Not in the first cut | Why | What brings it in by rule alone |
|---|---|---|
| machine_image, machine_image_version | creating an image requires a VM and captures a version that then blocks deleting the image; versions have no GET; a ready version makes itself latest behind terraform's back | image create without a VM (with an `arch` input); a version GET by label or `mv` id; a `set_as_latest` input; 204 for deleting a missing version; 409 rather than 400 while versions exist |
| private_location | the response's `name` is the AWS region, not the name every `{location}` takes; the path takes only the name, so a rename moves the address of every database in it | the response's `name` becomes the display name; `{location}` and the private location's path accept the ubid; a PATCH for credentials; `eu-central-1` in the region enum |
| postgres read replica and restore | each creates a new database through an action route on another, with the name in the body | `POST {pg}` accepts `restore_from` with `restore_target`, and a replica gets a collection route of its own; clause `name_carrier` then has no users |
| memberships: firewall subnets, subnet connections, cert auth users | none can be read back as a set, and the add routes are not idempotent | id sets in the responses and idempotent add and remove routes, then one membership rule with three users |
| plural datasources | the runtime would need pagination and a filter vocabulary | later, as general rules |
| kubeconfig, backup credentials, client keypair | each mints a secret, which calls for an ephemeral resource kind the runtime lacks | later, as one kind with three users |
| GitHub, capabilities, inference endpoints, audit log | no lifecycle; GitHub answers 501 without app configuration | datasources, if asked for |

The generator does not model the objects the server creates alongside a requested one: a VM's
default subnet, a subnet's default allow-all firewall, a database's customer firewall and subnet.
Where the API returns their ids (C24), they are computed attributes.

## 4. The derivation rules

Each rule is stated once, applies to every type, and is a method of `Derive` with the same name;
the provenance comments print that name. A rule names no type. Where a rule has a clause that
serves a single type today, the clause is named, prints in the provenance of the statements it
shapes, and is counted (§6.7).

### 4.1 Types and identity

**type_name.** An item path is a path that ends in a parameter and has a GET or a DELETE. Every item
path begins with the scope, `/project/{project_id}`; strip it, and `/location/{location}` if that
follows. The literal segments that remain before a parameter are the nouns. The type name joins
them with `_`, with hyphens turned into `_`, and a child noun that begins with its parent noun and a
hyphen drops the parent (`firewall/firewall-rule` gives `firewall_rule`, `postgres/firewall-rule`
gives `postgres_firewall_rule`, `kubernetes-cluster/nodepool` gives `kubernetes_cluster_nodepool`).
The scope path is named after its noun, `project`. Two item paths that derive the same name are an
error.

**kinds.** A type is named when its identity parameter accepts a name (schema `Reference`); the
name is then its create's idempotency key (§7.5). A type is a resource if `create_op` finds a
create. Every type has a datasource, which reads with the item GET that `crud_ops` requires.

**scope.** `{project_id}` is provider configuration, filled from the provider's `project_id`; it is
never an attribute. A token manages one project, so a per-resource project would repeat the token.

**location.** `{location}` is the attribute `location`: required, replaced on change.

**parent_key.** Every parameter between the scope and the identity, other than `{location}`, names
a parent: the attribute `<parent type name>_id`, required, replaced on change, checked against the
parent's `id` pattern. A response property of the same name is the same attribute.

**identity.** The last parameter is the identity. After the create, the provider addresses the
object by `id`, which every identity parameter in the first cut accepts, so a rename never moves
the address and no verb has to run last. When the create is a POST on the item, the identity
parameter fills `name`, and the parameter's checks are the name's.

**import_id.** The import id is made of the item path's attribute values after the scope, joined
with `/`. Parent parts are ids; the last part may be a name where the identity accepts one, and the
read that follows the import stores the id. The same attributes form the resource identity schema.

### 4.2 Operations

**create_op.** The create is the POST on the collection (the item path without its last parameter)
if there is one, otherwise the POST on the item. Its success response yields `id` and is otherwise
ignored, because state is written only from the item GET. Clause `union_collapse`: a response that
is a union of the item and an array of items is read as the item, and an array is a decode error.

**item_ops.** Read is the GET on the item, and delete is the DELETE on the item.

### 4.3 Attributes

**attribute_set.** The attributes are the keys and the properties of the create body, the verb
bodies and the item GET's response. A request property and a response property of the same name
are one attribute. Deprecated properties, and `readOnly` properties of request bodies, are left
out.

**required.** An attribute is required if it is a key, the name an identity fills, or a property
the create body requires without a `default`.

**optional.** Any other input is optional.

**computed.** An attribute is computed if it is a response property that no input carries, an
input with a `default`, or an optional input the response echoes, since the server may fill in
such an input when the configuration leaves it out. But an echoed input whose request property is
`nullable`, such as a VM's `maintenance_window_start_at`, is not computed, so that leaving it out
of the configuration sends null and clears the value. A required input is never computed.

**default.** A request property's `default` becomes the framework default, so the value is always
sent and a later change of the server's default cannot cause drift.

**write_only.** A `writeOnly` request property is never read back; state keeps the planned value,
and the datasource leaves it out.

**sensitive.** `format: password` on the request or the response property makes the attribute
sensitive.

**replace.** A change to a create input that no verb owns replaces the resource. For a write-only
input, the first apply after an import adopts the configured value instead of replacing (§7.4).

**stable.** A computed attribute keeps its prior value in a plan when it is `id`, an input, or a
`readOnly` output marked `x-immutable`. Every other computed attribute is unknown whenever the
resource is updated, because the server may change it.

**attr_type.** The response property is the canonical schema; the request property is used only
when no response property exists. Types map by a closed table that refuses anything else, naming
the spec location: `string`, `integer` (int64) and `boolean`; `format: date-time` to an RFC 3339
type; `format: cidr` and `format: port-range` to string types with semantic equality (§7.6); an
array to a list, or a set under `uniqueItems`; an object with `properties` to a nested object; an
object with typed `additionalProperties` to a map. `nullable` allows null. Other formats are only
documentation. An `anyOf` or `oneOf`, a free-form object or binary content in a canonical schema
is a `SpecError` naming the fix.

**checks.** Validators come from the request property's keywords, else the response property's:
`enum` gives a one-of check, `pattern` a regular expression, `minimum` and `maximum` bounds, and
`minLength` and `maxLength` length bounds. A pattern that Go's RE2 cannot compile (lookaround, a
backreference) is skipped, and the provenance says so. Checks apply only to inputs, and only to
strings and integers, since the engine checks no other type. The response's enum is the canonical
vocabulary where the request is looser: the firewall rule's request accepts `TCP` and the server
lowercases it, so the plan insists on `tcp`.

**doc.** An attribute's description is the response property's, else the request property's, else
the path parameter's; a parent key takes the parent's `id` description. A type's description is
its item response's.

**nesting.** An object nests to any depth, unless rule `ids` holds only its id. Objects in an input
always nest, because the configuration must be able to write every part of a body, such as the
`authorization` object in a metric destination's `options`. No cycle needs cutting: `Api` resolves
each `$ref` in place, which a cyclic spec would not allow.

**ids.** An object in a response whose schema is an item schema of a type the spec derives is held
as its id, typed as that type's `id`. A type's item schemas are those that its item GET's response
names by `$ref`, itself or as an `allOf` member, so `Firewall` is the firewall's, whose response
`FirewallDetailed` extends it. The attribute is the property's name with `_id` appended, or, for an
array, with a final `s` dropped and `_ids` appended, giving a list of ids, or a set under
`uniqueItems`; option `idsOf` names the property that the engine reads the objects from. So a VM has
`firewall_ids`; a firewall has `firewall_rule_ids` and `private_subnet_ids`; a cluster has
`cp_vm_ids` and `nodepool_ids`; and a postgres database has `read_replica_ids`, of its own type,
beside `firewall_rule_ids`, `log_destination_ids` and `metric_destination_ids`. A subnet's `nics`
and a database's `tags` have no type of their own and nest in full. The object's detail belongs to
its own type, and a configuration reads it through that type's resource or datasource. Held in
full, an object would show each change to it as drift on every resource that holds it, and would
put copies of it in state, as a nodepool would of each of its VMs; terraform providers refer to
another resource by id instead, as `aws_instance` does with `vpc_security_group_ids`. The type need
not be defined, so that defining a type changes no other type's attributes.

**lookup.** A datasource takes the keys as required arguments, and also `id`. Where the identity
accepts a name, it takes `id` or `name`, and exactly one of them must be given. A datasource of the
scope takes no arguments. Every other attribute is computed, a sensitive attribute stays sensitive,
and write-only attributes are left out.

### 4.4 Update verbs

**verb_candidates.** The candidates are the PATCH on the item, and every POST or PATCH on a direct
literal subroute (`{item}/<word>`) that has a request body and no path beneath it; a subroute with
paths beneath it is a child type's collection. Bodyless POSTs are actions, GET subroutes are reads,
and deprecated operations are skipped. A candidate is a verb when every property of its body,
`readOnly` ones aside, is in the create body or the item response, or is `writeOnly`. Three
clauses:

- `item_post_verb`: when the create is on the collection, the POST on the item is a candidate too.
- `merge_subroute`: a PATCH on a subroute merges into a sub-document and cannot express a removed
  key, so it is not a verb.
- `name_carrier`: a subroute body that carries the name together with other properties names a new
  object, and is not a verb.

**verb_order.** The definition's `order` comes first, then the item path's verbs, then subroutes by
path. A verb's name is its subroute word with `-` turned into `_`, or `patch` or `post` on the item.

**verb_owner.** Each attribute belongs to the first verb, in order, whose body carries it. A verb
left owning nothing is dropped, and the provenance records it.

**verb_body.** A verb runs when an attribute it owns differs between the plan and the state. It
sends every property of its body: the planned value, else the prior state's; a null is left out
unless the property is `nullable`. Bodies are absolute, so a verb can be retried; an upgrade, the
one verb that moves a value relative to the current one, takes its target in the body (C22, C33)
and is a no-op once there.

**after_create.** A verb that owns a configured attribute the create body lacks runs right after
the create settles. So an attribute that only a verb can set, such as a load balancer's `vms` or a
maintenance window, needs no definition word.

**adopt.** A changed attribute that no verb owns, which can only be a write-only input after an
import, is copied into state with no request.

### 4.5 Facts for the runtime

**lifecycle.** The property marked `x-lifecycle` gives a type's pending and failed values. After the
create and after each verb, the runtime reads the object while it is pending; a failed value ends
the wait with an error naming it, and a 404 ends it with "disappeared". A type with no `x-lifecycle`
does not wait. Waiting while pending, rather than until a ready value, is what lets a verb on a
stopped VM or an unavailable database return at once.

**gone.** After a DELETE that answered 2xx or 404, the runtime reads the object until 404. After a
synchronous delete the first read answers 404, so the same rule serves synchronous and asynchronous
deletes.

### 4.6 Timeouts

Every resource has a `timeouts` block with create, update and delete. The defaults are 120, 120
and 60 minutes for every type. The control plane's deadline for a kubernetes cluster's create is
120 minutes, and a default per type would need a definition word, so every type gets defaults long
enough for the slowest. A failed value or a 404 ends a wait early. Reads, which the block does not
cover, have a deadline of ten minutes.

### 4.7 Invariants

Derivation refuses a spec that breaks one of these, for defined types only, with the spec location
and the fix. The spec's defects therefore surface as failing specs in the generator's suite rather
than as wrong Go.

| Invariant | Statement |
|---|---|
| `one_item_path` | each definition names exactly one item path |
| `crud_ops` | a resource has a create, a GET and a DELETE on the item; a datasource has the GET |
| `create_response` | the create's success response is the item schema, its `allOf` base, or a union containing one |
| `input_echo` | every create or verb body property is echoed by the item GET's response, `writeOnly`, or deprecated |
| `closed_types` | every attribute's type is in `attr_type`'s table |
| `ids` | the name that rule `ids` gives an attribute is no other property's |
| `norms` | every operation of the type (its create, GET, DELETE and verbs) keeps the API's norms |

The other facts the spec must state are facts about the document, not about deriving a type, so
they are checked over the whole API. `typed_allof` (every `allOf` member has `type: object`) is
C11's Spectral rule. `direction`, `echo_agreement`, `lifecycle_enum`, `immutable_readonly`,
`examples` and `described` are norms in `openapi/norms.rb`, which clover's main suite runs over the
whole document against a list of known violations that may only shrink
(`doc/api-versions-design.md` §5). Rule `norms` runs the same file over a defined type's operations
with no known violations allowed, so a generated type keeps every norm.

`input_echo` is not the norm `echo`. The norm says that an operation answers with what it was
sent; the invariant says that the object read back holds it, which is what drift detection needs.
A config verb that answers with `PostgresConfig` keeps the norm and still needs C20 to keep the
invariant.

The norms `direction` and `echo` catch the mismatched pairs the API has today, such as
`enable_ip4` against `ip4_enabled`, `cp_nodes` against `cp_node_count`, and the private location's
two meanings of `name`. Derivation refuses each of them, where it would otherwise derive a
write-only input and, beside it, an unrelated computed attribute. The norm `echo_agreement` lets a
request be looser than its response, which is how the config maps keep accepting numbers while the
attribute is a map of strings.

## 5. Changes to the spec and the API

When derived output is wrong, the spec is fixed first, and where the spec cannot be made true
without the API changing, the API changes. A request and a response property for one value get one
name. Where the response already carries the requested value under another name, the request
accepts that name and deprecates the old one; where the response does not carry it, the response
gains it under the request's name.

A deprecated request name is marked `x-deprecated`, which states the first API version that
refuses it (`removed-in`) and, for a rename, the new name (`renamed-to`). Before the route runs,
`check_deprecations` gives a renamed input its new name, so a route reads only the new name.
Version 1, the default, keeps accepting a deprecated name with warnings, except in the configured
share of such requests that the brownout refuses. Version 2, which a client asks for in the Accept
header, refuses the names removed in version 2. `doc/api-versions-design.md` designs the versions,
the warnings and the brownout.

Kinds: **spec** changes no behaviour; **validated** changes response schemas, which committee checks
against every API response, in production too, so the commit must list every value the serializer
can produce, and route specs must reach every branch; **additive** adds fields, routes or accepted
inputs; **behaviour** fixes a bug without changing a shape; **breaking** changes what an existing
client reads or may send. A **dropped** change keeps its id, so that the others keep theirs. An
annotation change gives a family's properties what the norms and invariants require: `readOnly` on
response-only properties, `writeOnly` on inputs never echoed, `format: password` on secrets, the
defaults, enums and patterns the code already enforces, and descriptions and examples where they are
missing.

| Id | Change | Kind |
|---|---|---|
| C1 | Text: `latest_restore_time`'s stray `"`; `PostgresFirewallRule.description`; `PrivateLocation.provider`; the postgres rule DELETE's tag | spec |
| C2 | `deprecated` on inputs the routes ignore (firewall rule create `firewall_id` and `project_id`, load balancer PATCH `stack`), with `x-deprecated` removed in version 2, and on the response's `latest_restore_time`, which is the current time | spec |
| C3 | The three `anyOf` update bodies (`SshPublicKeyUpdate`, `FirewallRuleUpdate`, `PostgresPatchConfig`) become inline objects with every property optional and `minProperties: 1`; openapi_parser enforces `minProperties`, so the accepted bodies are the same, and inline bodies are outside Spectral's `required` rules | spec |
| C4 | `Retry-After` declared on `components/responses/Error`; a `fail_busy` helper raises a `CloverError` that sets it | additive |
| C5 | Uniqueness failures carry `details` keyed by the column the client chose, `name` for a name, so the runtime can attach the error to the attribute and tell a repeated create (§7.5) | additive |
| C6 | `r.rename` takes serializer options; vm, load balancer, postgres, cluster and nodepool renames and postgres promote return the detailed body the spec promises | additive |
| C7 | `FirewallDetailed`'s second `allOf` member typed; the firewall serializer always emits `path` | validated |
| C8 | `LoadBalancer` typed; `vms` items are ubid strings with `uniqueItems`; `location`, `stack`, `cert_enabled` required | validated |
| C9 | `Vm` typed; `gpu` and `subnet` nullable | validated |
| C10 | `PostgresDatabase` typed; `metric_destinations`, `log_destinations`, `read_replicas` documented; restore times optional, `earliest_restore_time` a date-time; duplicated properties removed; `maintenance_window_days` always emitted | validated |
| C11 | A Spectral rule that every `allOf` member has `type: object` | spec |
| C12 | Load balancer create defaults `stack` to `dual`; its PATCH keeps `cert_enabled` when absent; firewall PATCH accepts an empty description, as create does | additive |
| C13 | Load balancer create looks the subnet up in the path's location; a new load balancer's name must be unique in its project and location | behaviour |
| C14 | A bare IPv6 address is stored as `/128`, as a bare IPv4 address is stored as `/32`; NetAddr's default gives `/64` | behaviour |
| C15 | `private_subnet_id` in the vm and load balancer responses | additive |
| C16 | VM create accepts `ip4_enabled`, `gpu_count`, `gpu_device` (deprecating `enable_ip4`, renamed to `ip4_enabled`, and `gpu`); the response gains `storage_size` (each volume's size, as requested), `gpu_count`, `gpu_device`; the CLI sends the new names | additive |
| C17 | Annotations for ssh keys, inference keys and the project: `readOnly`, `format: password` and `x-immutable` on the key, examples; `openapi/README.md` defines `x-lifecycle` and `x-immutable` | spec |
| C18 | Annotations for the network family: `readOnly`, `writeOnly`, defaults, enums on both sides of the load balancer's enumerated fields, formats `cidr` and `port-range`, patterns, `x-immutable` on `net4` and `net6`, the private subnet's `state` enum (with `creating`, the column default) and `x-lifecycle`, examples | validated |
| C19 | Annotations for the VM, with its `state` enum and `x-lifecycle`, `x-immutable` addresses, `format: password` on `init_script` | validated |
| C20 | `pg_config` and `pgbouncer_config` in the detailed postgres response; the server stores config values as strings and returns them so | additive, behaviour |
| C21 | Postgres keeps the requested size and storage apart from the targets auto-scale raises; the response gains `size` and `storage_size`; a PATCH moves a target only when the requested value changes | additive, behaviour |
| C22 | Postgres create accepts `target_version` (deprecating `version`, renamed to `target_version`); its upgrade accepts an optional `{target_version}`, which must be the next version, and answers 200 doing nothing when already there | additive |
| C23 | Postgres `set-maintenance-window` accepts a null `start_at` and empty days without the project flag; `start_at` is 0 to 23 on both resources | additive |
| C24 | `private_subnet_id` and `firewall_id` in the detailed postgres response | additive |
| C25 | Annotations for postgres, with its `state` enum and `x-lifecycle`, `ha_type`'s enum and default, `restrict_by_default`'s default | validated |
| C26 | GET on one postgres firewall rule, log destination and metric destination; a `PostgresMetricDestination` schema | additive |
| C27 | A postgres firewall rule's PATCH and DELETE also act on its 6432 twin; the list and the detailed postgres response show each pair once, by its 5432 row; `port` deprecated | behaviour |
| C28 | Typed `options` for both destinations, from the shapes the routes enforce; `writeOnly` and `format: password` on them and on the metric password; annotations | spec |
| C29 | Metric destination create returns the destination, in every API version; the CLI reads the list with a GET | breaking |
| C30 | Postgres refuses the legacy `burstable-*` sizes, which it now rewrites to `hobby-*` behind the client's back (whether version 1 may keep them as deprecated values is open, `doc/api-versions-design.md` §11) | breaking |
| C31 | Kubernetes `state` on cluster and nodepool (deprecating `display_state`, which stays in every version's responses); a cluster with a kubeconfig reads `running` unless deleting or upgrading; detailed-only fields in a typed member; `services_load_balancer_url` serialized | validated, behaviour |
| C32 | GET on one nodepool | additive |
| C33 | Optional `{version}` on both kubernetes upgrades, a no-op when already there; optional `version` on nodepool create | additive |
| C34 | Kubernetes busy refusals use `fail_busy`; "busy" and "nothing to do" get separate messages | additive |
| C35 | Cluster create accepts `cp_node_count` (deprecating `cp_nodes`, renamed to `cp_node_count`) and takes its name through a `kubernetes_cluster_new_name` parameter limited to 37 characters | additive |
| C36 | A cluster may be created without a default nodepool, and its last nodepool may be deleted; `worker_size` and `worker_nodes` deprecated, removed in version 3 unless Daniel decides otherwise (`doc/api-versions-design.md` §11) | additive |
| C37 | Annotations for kubernetes | spec |
| C38 | Dropped: an `Idempotency-Key` header on every create. The name is a named type's idempotency key (§7.5), and a type without a name reports | dropped |

Some things are deliberately left alone: the operationIds, which are inconsistent but which no rule
reads; the postgres upgrade's needs-convergence refusal, which can last until the maintenance
window and so gets no `Retry-After`; and postgres `init_script`, which the routes read and the spec
refuses.

## 6. Emission

### 6.1 One mechanism

`TerraformGenerator::Go` renders the model in one place, by class, as Sequel's `literal_append`
does. There are no templates and no Go in Ruby strings outside this renderer and the file skeleton:

```ruby
module TerraformGenerator::Go
  def self.literal(v)
    case v
    in Call then "#{camel(v.name)}(#{args(v.args)})"           # listOf(str), atLeast(1)
    in Nested then "#{camel(NESTED.fetch(v.kind))}(#{v.var})"   # listOf(o_nics)
    in Symbol then camel(v)                                     # a type or a flag: writeOnly
    in Set then v.map { camel(it) }.join("|")                   # flags: required|replace
    in String if v.include?("\\") && !v.match?(/[`\x00-\x1f]/) then "`#{v}`"
    in String then JSON.generate(v)                             # a JSON string is a Go string
    in Integer | true | false then v.to_s
    end
  end
end
```

A statement record renders as `receiver.<class name>(members...)`, with symbols in lower camel case
(`:write_only` is `writeOnly`); `Type` renders as `t := newType(name, item, doc)` and closes with
`register(t)`, and `Dropped` renders as a comment line only. A nested object renders first, as
`o_<attribute> := object()` followed by an `o_<attribute>.attr(...)` statement for each of its
properties. An object nested in another renders the same way, before the outer object's statement
that uses it, and its variable is the outer object's variable, an underscore and its property's
name, as in `o_options_authorization`. `TerraformGenerator::Hcl` writes the HCL examples the same
way.

### 6.2 The module

```
terraform/provider/                      Go module github.com/ubicloud/terraform-provider-ubicloud
  go.mod, go.sum                         hand-written, tidy; tfplugindocs as a tool
  main.go
  internal/provider/
    provider.go spec.go schema.go        the engine (§7), hand-written, with *_test.go
    convert.go client.go resource.go
    datasource.go wait.go types.go
    <type>_gen.go                        generated, one per type; registers itself in init(); ignored
  examples/resources/ubicloud_<type>/resource.tf, import.sh       generated; ignored
  examples/data-sources/ubicloud_<type>/data-source.tf            generated; ignored
  examples/provider/provider.tf, templates/index.md.tmpl          hand-written
```

The generated files sit in the engine's package and import nothing, so an import list can never be
wrong in a way only Go would see. Because each file registers its type in `init()`, adding a type
touches no shared generated file. The generated files are not committed, and `.gitignore` lists
their paths. Documentation is generated by tfplugindocs at release, and into `tmp/` in the terraform
workflow to check that it builds; it is not committed either.

### 6.3 A generated file

Here is the complete `firewall_rule_gen.go`:

```go
// rake terraform:generate; rake terraform:diff; sha256:200e4d0a5afcd1f2

package provider

func init() {
	// type_name@getLocationFirewallFirewallRuleDetails doc@FirewallRule
	t := newType("firewall_rule", "/project/{project_id}/location/{location}/firewall/{firewall_id}/firewall-rule/{id}", "A Firewall Rule")
	// create_op@createLocationFirewallRule union_collapse@FirewallRuleOrRules
	t.create("POST", "/project/{project_id}/location/{location}/firewall/{firewall_id}/firewall-rule", "cidr", "description", "port_range", "protocol")
	// required@createLocationFirewallRule.cidr attr_type@FirewallRule.cidr
	t.attr("cidr", stringOf("cidr"), required, "CIDR of the firewall rule")
	// default,stable@createLocationFirewallRule.description
	t.attr("description", str, optional|computed|stable, "Description of the firewall rule", defaultString(""))
	// parent_key,replace@{firewall_reference} checks@FirewallDetailed.id
	t.attr("firewall_id", str, required|replace, "ID of the firewall", matches("^fw[0-9a-hj-km-np-tv-z]{24}$"))
	// identity@{firewall_rule_id} stable@FirewallRule.id
	t.attr("id", str, computed|stable, "ID of the firewall rule")
	// location,replace@{location}
	t.attr("location", str, required|replace, "The Ubicloud location/region")
	// default,stable,checks@createLocationFirewallRule.port_range attr_type@FirewallRule.port_range
	t.attr("port_range", stringOf("port-range"), optional|computed|stable, "Port or port range of the firewall rule, such as 443 or 8000..8080", defaultString("0..65535"), matches(`^\d+(\.\.\d+)?$`))
	// default,stable@createLocationFirewallRule.protocol checks@FirewallRule.protocol
	t.attr("protocol", str, optional|computed|stable, "Protocol of the firewall rule (tcp or udp)", defaultString("tcp"), oneOf("tcp", "udp"))
	// verb_candidates@modifyFirewallRule
	t.verb("PATCH", "", "cidr", "description", "port_range", "protocol")
	register(t)
}
```

Paths are written in attribute names (`{firewall_id}`, `{id}`, `{name}`), and `{project_id}` is
filled from the provider. A create's path is absolute; a verb's is relative to the item path, and
`""` is the item itself. Other types use the remaining statement kinds, as these excerpts from the
postgres and vm files show:

```go
	// kinds@{postgres_database_reference}
	t.datasource("id", "name")
	// lifecycle@PostgresDatabase.state
	t.pending("state", "creating", "deleting", "finalizing_restore", "replaying_wal", "restarting", "restoring_backup")
	// default,replace,stable,write_only,attr_type@createPostgresDatabase.restrict_by_default
	t.attr("restrict_by_default", boolean, optional|computed|replace|stable|writeOnly, "Whether to restrict access by default (if so, firewall rules must be added to access)", defaultBool(false))
	// verb_order@definitions.rb verb_candidates@upgradePostgresDatabase
	t.verb("POST", "/upgrade", "target_version")
	// verb_candidates@patchPostgresDatabase
	t.verb("PATCH", "", "ha_type", "size", "storage_size", "tags")
	// merge_subroute@patchPostgresDatabaseConfig
	// verb_candidates@updatePostgresDatabaseConfig
	t.verb("POST", "/config", "pg_config", "pgbouncer_config")
	// name_carrier@createPostgresDatabaseReadReplica
```

```go
	// lifecycle@Vm.state
	t.failed("state", "no capacity available")
	// computed,attr_type@Vm.firewalls ids@FirewallDetailed.id
	t.attr("firewall_ids", listOf(str), computed, "Firewalls that apply to the VM", idsOf("firewalls"))
```

### 6.4 Provenance

Every statement has one comment line directly above it, so the comment is inside the three lines
of context of any diff that touches the statement. The comment is a pointer back to what made the
line, as terse as a debug symbol and meant for an engineer or an LLM to follow, not to read as
prose: each source once, after the rules that read it, as `rule,rule@source`, the groups separated
by spaces. A rule is a method of the generator: `Derive`'s, except `type_name`, which is `Api`'s.
`grep -n "def checks" terraform/lib` finds rule `checks`, and a clause is a method of its own. A
source is a component and property (`FirewallRule.cidr`), an operationId and property
(`createLocationFirewallRule.cidr`), an operationId, a path parameter in braces
(`{firewall_reference}`), or `definitions.rb` for a definition's `order`; `!re2` after a source
marks a pattern that the check skipped because RE2 cannot compile it. A pointer is never a line
number, of the spec or of the generator, so that an edit elsewhere in either rewrites no generated
line. A candidate verb that a rule set aside leaves a comment line naming the rule and the
operation. The header is one line, naming the command that wrote the file and the command that
shows what is left to carry back, and ending in the stamp (§6.6).

The comment also tells where an edit to that line should be carried back, to one of the brief's
three places: a spec location points to the spec, `definitions.rb` to the definitions file, and a
rule name to the rule, when the edit is one that every type would want. The table in §9 lists each
kind of edit.

### 6.5 Determinism and gofmt

Attributes, nested attributes, body lists and files are sorted by name; verbs keep rule order;
there are no timestamps and no machine-specific paths; strings are escaped one way. Output depends
only on the spec and the definitions file.

The renderer writes only forms that gofmt leaves alone, so a generated file on disk is the render
byte for byte and its stamp (§6.6) holds without running Go. Every statement is one line, indented
by one tab, with its comment on the line above; there are no keyed composite literals and no struct
fields, which gofmt would align; there are no trailing comments, no blank line after `{` or before
`}`, and one newline at the end. After generating, the terraform workflow runs `gofmt -l` over
`terraform/provider` and fails if it lists any file, so a rendered line in any other form is
caught, and so is a badly formatted file in the hand-written engine. The examples align `=` within
a block, as `terraform fmt` does, and the workflow runs `terraform fmt -check` on them.

### 6.6 Stamps and statuses

Each generated file carries a stamp: the first 16 hex digits of the SHA-256 of the body below the
header. With it the generator tells a pristine file, safe to overwrite, from an edited one. Git
ignores the generated files and cannot tell, so the stamp is what makes `rake terraform` safe to run
at any point during a carry-back. Each file gets one of these statuses:

| Status | Meaning | `rake terraform:generate` | strict (`terraform:check`, `CHECK=1`) |
|---|---|---|---|
| new | rendered, not on disk | write | write |
| unchanged | on disk, equal to the render | nothing | nothing |
| stale | stamp intact, body differs from the render | rewrite | rewrite |
| edited | stamp broken, body differs from the render | keep, report | fail |
| carried | stamp broken, body equals the render | restamp | restamp |
| orphan | generated header, no definition renders it | delete if pristine, report if edited | fail |

A file at a generated path without the header is a collision, and the generator raises an error;
hand-written files carry no header and are never touched. `FORCE=1` overwrites edited files. An
orphan is what the brief calls "a generated file that no definition produces". `generate` renders
every file before it writes any, and writes through a temporary file and a rename, so a failed
derivation writes nothing.

Since nothing generated is committed, there is no golden file to compare a render with. The
terraform workflow generates afresh on every run, and strict mode fails only on an edited or
orphaned file, or when derivation refuses the spec. A commit that changes the API in a way that
alters the provider therefore commits no generated files, and the workflow's harness tries the new
render against the API.

### 6.7 The special-case tally

The brief asks that special cases be counted. `TerraformGenerator.special_cases` returns, by name,
each definition key used by one type and each rule clause that shaped one type's statements. A
spec in the generator's suite pins that tally, and `rake terraform:check` prints it. For the first
cut the pin should read:

```ruby
expect(special_cases).to eq(
  "definitions order" => %i[postgres],
  "item_post_verb" => %i[ssh_public_key],
  "merge_subroute" => %i[postgres],
  "name_carrier" => %i[postgres],
  "union_collapse" => %i[firewall_rule]
)
```

A new special case therefore shows up in review as a new named line in the pin. Four of the special
cases above have a known way out: `order` by folding the postgres verbs into its PATCH;
`item_post_verb` by a PATCH on ssh keys; `name_carrier` by the create inputs of §3.3; and
`union_collapse` by a separate subnet input on firewall rule create.

### 6.8 Examples

**example.** A resource's example sets its required inputs, and, where the create's request body has
an `example`, the inputs that example sets. A body can need one of several optional inputs, which
the examples of single properties cannot say: a metric destination needs a username and password, or
options. Each value comes from the body's example, else from `example` on the request property, else
on the path parameter, else on the response property of the same name. A parent key, and an input
whose pattern is another type's `id` pattern, refer to that type's example
(`private_subnet_id = ubicloud_private_subnet.example.id`), whose block the same file includes.
`import.sh` shows the derived import id built from the `id` examples, and a datasource's example
looks the object up by `name` where it can, else by `id`. The norm `examples`, which rule `norms`
applies to every defined type, makes a missing value a `SpecError`. Because the harness applies
every example (§8.2), a value the API refuses fails CI on the day it lands.

```hcl
# rake terraform:generate; rake terraform:diff; sha256:637f820451f74f9d

resource "ubicloud_firewall" "example" {
  location = "eu-central-h1"
  name     = "my-firewall"
}

resource "ubicloud_firewall_rule" "example" {
  cidr        = "0.0.0.0/0"
  firewall_id = ubicloud_firewall.example.id
  location    = "eu-central-h1"
}
```

A datasource's example refers to its resource's example where the type has one, as in
`name = ubicloud_firewall.example.name`, so that the harness can apply the two together and compare
what each reads.

## 7. The Go runtime

### 7.1 Files

The runtime is written by hand, once for every type, and comes to about 1,500 lines with its tests.
The generated files are data for it. It targets current terraform, the 1.15.8 that `mise.toml`
pins, and uses resource identity; it does not try to support older versions.

| File | Holds |
|---|---|
| `provider.go` | provider schema: `api_endpoint` (default `https://api.ubicloud.com`, `UBICLOUD_API_ENDPOINT`), `api_token` (sensitive, `UBICLOUD_API_TOKEN`), `project_id` (`UBICLOUD_PROJECT_ID`), `poll_interval` (default 5 s); the registered types |
| `spec.go` | the descriptor types and the builder functions the generated files call; `validate`, which checks that every placeholder and body name is an attribute, that the lifecycle and lookup attributes exist, and that a resource's item path ends in `{id}` |
| `schema.go` | descriptor to framework resource schema, datasource schema (rule `lookup`), identity schema and `timeouts` block; plan modifiers and validators from flags and checks |
| `convert.go` | JSON to framework values and back, guided by the descriptor: strict on known properties (a mismatch is an error naming the JSON path), unknown properties ignored, so an older provider survives a newer API |
| `client.go` | the one transport: bearer token, `User-Agent: terraform-provider-ubicloud/<version>`, `Accept: application/vnd.ubicloud+json; version=2`, JSON with numbers kept exact, a one-minute limit on each request, rule `retry`, a debug log line for each request, without the token, and the API's error body decoded |
| `resource.go` | the generic resource: Create, Read, Update, Delete, ImportState, IdentitySchema |
| `datasource.go` | the generic datasource |
| `wait.go` | `settle` and `gone` |
| `types.go` | the `cidr` and `port-range` string types; the plan modifiers for `stable` and `replace`, replace-unless-imported among them |

### 7.2 The builder vocabulary

```go
func newType(name, item, doc string) *typeDesc
func (t *typeDesc) create(method, path string, body ...string)
func (t *typeDesc) datasource(lookup ...string)
func (t *typeDesc) pending(attr string, values ...string)
func (t *typeDesc) failed(attr string, values ...string)
func (t *typeDesc) verb(method, path string, body ...string)
func object() *objectDesc
func (o *objectDesc) attr(name string, ty attrType, f flag, doc string, opts ...option)
func register(t *typeDesc)
```

A `typeDesc` embeds an `objectDesc`, so the same `attr` declares the attributes of a type and those
of a nested object. Types are `str`, `i64`, `boolean`, `timestamp`, `stringOf(format)`, `listOf`,
`setOf`, `mapOf` and `single`; flags are `required`, `optional`, `computed`, `sensitive`,
`replace`, `stable`, `writeOnly` and `nullable`; options are `matches`, `oneOf`, `atLeast`,
`atMost`, `defaultString`, `defaultInt`, `defaultBool` and `idsOf`. `atLeast` and `atMost` bound an
integer, or the length of a string. `idsOf(property)` reads the attribute from that response
property, taking the `id` of each object there (rule `ids`). `stable` becomes a plan modifier that keeps the prior value when the
plan does not know it, as UseStateForUnknown does. `replace` becomes one that requires
replacement, or, together with `writeOnly`, the replace-unless-imported modifier.

### 7.3 A resource's life

**Create.** Build the body from the planned create inputs and POST it, filling the path from the
plan. On a 4xx that is not retried (§7.5), map `details` keys to attribute errors and stop. On
success take `id` and set the partial state at once (keys, `id`, planned inputs), so that a later
failure leaves a resource terraform marks tainted rather than an orphan. Then settle, run the
`after_create` verbs, each followed by a settle, and read.

**Read.** GET by id. A 404 removes the resource from state. Computed values come from the response,
write-only values from the prior state.

**Update.** For each verb in order whose owned attributes changed, send it and settle. Copy adopted
attributes into state. If a verb fails, write the prior state, with the planned values of the
attributes that the verbs before it own, and then return the error. That way the changes those
verbs made, a rename for instance, are not lost, and the next refresh reads the rest. Otherwise
the state comes from the read after the last verb, or from a single read when no verb ran.

**Delete.** Send the DELETE, treating 204 and 404 as success, then run `gone`.

**Import.** Split the id on `/` into the item path's attributes and set the identity; the read that
follows resolves a name to the id. An id with the wrong number of parts fails with an error that
gives the expected format, derived from the item path. ImportState also writes the private-state
marker of §7.4.

**Datasource.** GET by `id`, or by `name` where the lookup allows it; the scope's datasource reads
the provider's project.

### 7.4 Write-only inputs and import

The API never echoes a write-only input, so after an import its state is null, and a plain
RequiresReplace would replace every imported VM because of its required `public_key`, and every
imported database whose configuration sets `restrict_by_default`. Since users of the old provider
must re-import everything, this would destroy their objects. ImportState therefore writes the
private-state key `imported`. While that key is present and the prior value is null, the
replace-unless-imported modifier adopts a configured value instead of replacing; Update clears the
key. A resource the provider created never carries the key, so adding `restrict_by_default = true`
to a database created without it plans a replacement, as it must, rather than claiming a
restriction the server never applied.

### 7.5 Waits, retries and ambiguous creates

`settle` and `gone` read at once and then again after `poll_interval`, doubling the wait each time
up to six times the interval, until the operation's deadline from the `timeouts` block. A deadline
error names the last state seen and the `timeouts` key to raise.

**retry.** A response that carries `Retry-After`, or a 429, is retried after the longer of the
header's delay and the poll interval, until the deadline. This holds for every request, creates
included, because a refusal has changed nothing. A 502, 503 or 504 without `Retry-After`, or a
transport error, is retried after the poll interval for reads, deletes and verbs, which are all
safe to repeat, verbs because their bodies are absolute. Five such failures in a row end the
request. A create is retried only when the request was not completely sent; otherwise the create
is ambiguous. A 500 is a server bug and is reported.

**ambiguous create.** A create is ambiguous when the request may have reached the server and no
usable answer came back: a transport error after the request was written, a 502, 503 or 504, a
deadline during the POST, or a 2xx whose body does not decode. For a named type the name is the
create's idempotency key; a type is named when its datasource takes `name` (rules `kinds` and
`lookup`). The runtime reads the object by name, as the datasource does; if it is found, the runtime
adopts it, taking its `id` as a successful create would, and goes on as Create does. On a 404 it
sends the create again. A 400 to the repeated create, its `details` keyed by `name` (C5), means the
object exists, so the runtime reads by name again. This repeats until the create's deadline. An
object of that name that existed before the apply is adopted too. A type without a name has no key,
so the runtime reports the problem and adopts nothing. The report names the parent to list and the
import to run. Terraform does not tell a provider a resource's address, so the suggested import
leaves the address for the user to fill in: "The create may have taken effect. If it did, the object
is under …; import it with: terraform import ADDRESS eu-central-h1/fw…/ID".

### 7.6 Formats and diagnostics

`cidr` values are equal when their networks are equal, with host bits masked and a bare address
read as `/32` or `/128`; `port-range` values are equal when they cover the same ports, so `a..a`
equals `a`. Both canonicalize as the server does after C14 (`model/firewall_rule.rb`,
`Validation.validate_cidr`), so a plan keeps what the user wrote and never reports an inconsistent
result. RFC 3339 values use terraform-plugin-framework-timetypes.

Diagnostics have one form: a summary such as "Error creating ubicloud_vm", and a detail such as
"POST /project/…/vm/web: 400 InvalidRequest: <message>", followed by attribute errors from
`details`. A body that does not decode is an error naming the JSON path, never an empty success. A
settle failure names the value; a timeout names the last value seen.

### 7.7 What the runtime does not have

The runtime has no per-type Go, no hand-built struct for any response, no state upgrader (users
re-import), no schema versions, and no environment variables named after a type.

## 8. Tests

### 8.1 The generator's suite: the derivation, without Go

`terraform/spec/`, with a spec per file of the generator in `terraform_generator/`:

| Spec | Covers |
|---|---|
| `terraform_generator_spec.rb` | the module's `files`, over a small spec |
| `api_spec.rb` | `$ref` in schemas, parameters, responses and request bodies; `allOf` merging; the item index and `type_name` |
| `derive_spec.rb` | one `describe` per rule, clause and invariant, each example a small spec built inline by the helper `thing(...)`, which `derive` and `derive_attr` wrap |
| `go_spec.rb`, `hcl_spec.rb` | the literals by class, quoting, statements and the file skeleton |
| `tree_spec.rb` | the six statuses, stamps, collisions and `FORCE`, in a temporary directory; an unchanged file's mtime is left alone |
| `definitions_spec.rb` | closed keys, unknown names with their candidates, an `order` that names no verb |
| `special_cases_spec.rb` | how the tally counts, and the pin of §6.7 |

A derive example is three to ten lines. The helpers build a spec with one item path whose GET
returns a `readOnly` `id`, and add what the example names:

```ruby
it "replaces a write-only create input that no verb carries" do
  attr = derive_attr(:public_key, create: {public_key: {type: "string", writeOnly: true}})
  expect(attr.flags).to eq Set[:optional, :replace, :write_only]
end

it "refuses a body property that the response holds only as deprecated, which norm_echo accepts" do
  expect_refusal("createThing.color: neither in the response nor writeOnly; mark it writeOnly " \
    "or echo it", create: {color: {type: "string"}}, response: {color: deprecated})
end
```

The suite has its own `spec_helper.rb` and `.rspec`, needs no database and loads no part of clover;
`cd terraform && bundle exec rspec` runs it, under clover's bundle. Every error branch has an
example, so each file in `terraform/lib` reaches 100% line and branch coverage; the suite measures
it with SimpleCov when `COVERAGE` is set, at the same thresholds as clover's
`spec/coverage_helper.rb`. No spec shells out. The terraform workflow runs the suite, as do the
people who work on the generator; clover's main suite does not.

Clover's main suite gains two checks. `spec/openapi_norms_spec.rb` holds a passing and a failing
example for each norm, and checks the whole spec against `openapi/norms-known.txt`
(`doc/api-versions-design.md` §5). Alongside the route specs, a second spec checks each `state`
enum against the values the model's `display_state` can return, because a value missing from the
spec would answer 500 in production.

### 8.2 The terraform harness

The harness runs real terraform and the real provider binary against clover's API in process, so
that a terraform misbehaviour is written as an rspec example. `doc/terraform-harness-design.md`
designs it; in short:

- It lives in `spec/terraform/`, in files named `*_harness.rb`, which the main suite's pattern
  leaves out.
- The API runs on the example's thread, through `RACK_TEST_APP`, inside the example's rollback
  transaction, so committee, authorization and duplicate-query detection check every request the
  provider sends, and the rollback is the cleanup.
- No prog runs. After the API accepts a change, a hook per table, `settle_<table>`, puts the object
  at rest, as the control plane would, so that the provider's waits (rule `lifecycle`) end.
- A gate injects a fault at a request (`:request`) or at its answer (`:response`), and the ledger
  lets an example assert which requests the provider sent, in what order.
- The first harness file to load generates the provider's files, keeping edited ones, and then
  always runs `go build`, which takes a fraction of a second when nothing has changed. Running the
  harness directly with rspec therefore never tests a stale provider, and never loses an edit.
- `spec/terraform/examples_harness.rb` applies every generated resource example, checks that a
  plan then shows no change, and destroys it, so every type is tried against the API without a
  line written for it. The commit that adds a type writes an example for each of its update verbs
  and, for a named type, an import.

### 8.3 The workflow

`.github/workflows/terraform.yml` runs on every pull request, on every push to main, and on manual
dispatch, with no path filter, because a change in `routes/`, `serializers/` or `prog/` can break
the provider without touching the spec. It is a required check, so such a change cannot merge.
Here is the workflow:

```yaml
name: Terraform provider
on: {pull_request: {}, push: {branches: [main]}, workflow_dispatch: {}}
permissions: {contents: read}
jobs:
  terraform:
    runs-on: ubicloud-standard-4
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: {persist-credentials: false}
      - uses: $/.github/actions/setup-clover
      - uses: jdx/mise-action@<sha> # pinned when added
        with: {install_args: go terraform}
      - run: bundle exec rake terraform CHECK=1 COVER=1
      - if: failure()
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with: {name: terraform, path: tmp/terraform/}
```

It runs the command an engineer runs, in strict mode, and checks the coverage of the hand-written
engine. The target is 100% statement coverage, counting `go test` and the harness together. With
`COVER=1`, `go test -cover` writes its counters to one coverage directory (`-test.gocoverdir`); the
provider binary is built with `go build -cover`, and every terraform run in the harness gives it a
second directory as `GOCOVERDIR`; and `go tool covdata textfmt` reads both into one profile, from
which the report names each uncovered statement. The generated `*_gen.go` files are data and are
not counted. An important regression may also get a test of its own, in either layer. The
generator's suite measures the coverage of `terraform/lib`, and the harness measures no Ruby
coverage, so the main suite's coverage needs no merge across workflows. The everyday loop, `rake`
and the main suite, never runs Go, terraform or the generator. The workflow meets zizmor's rules:
pinned actions, read-only permissions, no persisted credentials. It should take about two minutes,
most of it setup.

### 8.4 The one command

`bundle exec rake terraform` runs the whole loop, and `rake -T terraform` lists it and its parts:

1. **Preflight.** Check `go version` and `terraform version` against `mise.toml`, and if either
   differs, print `mise install` and stop. Check that the test database is reachable and migrated,
   and if not, print `rake setup_database[test,true]` and stop.
2. **Generate.** Write the generated files, keeping edited ones, and print each file's status.
   With `CHECK=1`, fail on an edited or orphaned file.
3. **Generator's suite.** Run rspec in `terraform/` with `COVERAGE=1`, so that a file short of 100%
   line or branch coverage fails it.
4. **Module checks.** Run `gofmt -l`, which must print nothing, then `go vet ./...`,
   `go mod tidy -diff`, and `go test ./...`, which runs `validate` over every registered type. Run
   `terraform fmt -check` on the examples, and tfplugindocs into `tmp/`.
5. **Harness.** Run rspec over `spec/terraform/**/*_harness.rb`, which builds the provider first.
6. **Report.** Print the engine's merged statement coverage and each statement left uncovered.

The parts:

```
rake terraform:generate   write the generated files, keeping edits; print statuses     FORCE=1
rake terraform:diff       render in memory; diff the render (---) with disk (+++); write nothing
rake terraform:check      strict statuses, the tally, gofmt, vet, go mod tidy -diff, go test,
                          terraform fmt
rake terraform:harness    the harness, which generates and builds first
```

Every task sets `GOTOOLCHAIN=local`, so the wrong Go version fails with the `mise install` message
instead of downloading a toolchain. The command is safe to repeat: generation is deterministic and
the database rolls back. A warm run should take about two minutes.

### 8.5 Installing Go and terraform

`mise.toml` pins terraform 1.15.8 and Go 1.27.3, the version the module's `go` directive names, and
`mise.lock` records their checksums. So `mise install`, which DEVELOPERS.md already prescribes,
provides Go and terraform along with Ruby and Node. `cli-ci.yml` keeps taking its Go from
`cli/go.mod`. Dependabot gains a `gomod` entry for `terraform/provider/`.

## 9. Carrying an edit back

Here is the brief's loop, with the commands for each step:

1. An engineer edits generated files under `terraform/provider/` (drops a `replace`, adds a check,
   reorders a verb) and runs `rake terraform`. The edited files keep the status `edited`, and are
   built and tried against the API.
2. The engineer hands the work to an LLM, which runs `rake terraform:diff`. Each `+` line is an edit
   not yet carried back, and the comment above it names the rule and the spec location.
3. For each hunk the LLM changes one of three things, as the comment indicates: the spec, a fact in
   the definitions file, or a rule. It runs the derivation specs after each change, then the diff
   again.
4. When the diff is empty the edit is carried back. The next `generate` restamps the edited files
   (status `carried`), and the commit holds the spec, definition or rule change; the generated files
   are not committed.

| Edit in a generated file | Carried back as | Kind |
|---|---|---|
| `required` or `optional` changed | `required`, `writeOnly`, or the property's presence in a body | spec, maybe API |
| `sensitive` added | `format: password` | spec |
| a check added | `pattern`, `enum`, `minimum`, `maximum`, `minLength` or `maxLength` on the request property | spec |
| a default | `default` on the request property | spec |
| `replace` removed | the attribute added to an update verb's body | API, additive |
| `stable` on an output | `x-immutable` | spec |
| a pending or failed value | `x-lifecycle` | spec |
| verbs reordered | `order` in the definition | definition |
| a new verb or body field | the route and its spec | API |
| an example value | `example` on the property | spec |
| a change every type would want | a rule in `derive.rb`, or the renderer | rule |

A rule that names one type is refused in review; a clause that serves one type is named and
counted. An edit to the engine is not carried back, because the engine is hand-written source, not
output.

## 10. Open questions

Daniel Farina answered the design's first open questions on 2 Nov 2026. Three things remain open:

- Release and version. How the new provider is released, and what version it carries, are not
  designed yet.
- The comparison of old and new. Once the types are generated, the old provider and API are
  compared with the new ones, to show what the incompatible change costs and what it buys: in
  Daniel's words, "to see what the cleanliness picked up is".
- Whether coverage short of 100% fails the workflow. Daniel's word is "target" ("You can target
  100% in go, though, I suspect it won't be easy"); until he decides, the report names each
  uncovered statement and the workflow does not fail on them.

The designs of the harness and of the API versions list further open questions, in
`doc/terraform-harness-design.md` §8 and `doc/api-versions-design.md` §11, each with a default that
holds until it is answered.
