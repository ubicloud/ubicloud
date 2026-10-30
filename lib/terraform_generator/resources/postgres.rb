# frozen_string_literal: true

TerraformGenerator.resource :postgres do
  route "postgres"

  # Config and tags are excluded from the create body: config is the
  # config-merge verb's territory, and tags are not routed.
  omit "__create__.pg_config", "__create__.pgbouncer_config", "__create__.tags",
    "__patch__.tags",
    kinds: [:resource]

  # Alias pairs: the API reports canonical names; the resource
  # schema exposes user-facing aliases alongside them.
  attr :vm_size, also_tf: :size, kinds: [:resource]
  attr :storage_size_gib, also_tf: :storage_size, kinds: [:resource]

  volatile :latest_restore_time, :earliest_restore_time

  unread_map :pg_config, :pgbouncer_config

  # Curation delta: the PATCH body also accepts tags, which terraform
  # does not route through this verb.
  update_verb :patch, route: :patch, attrs: %i[size storage_size ha_type],
    blocked_when: {attr: :parent, summary: "Cannot update a read replica",
                   detail: "patch changes are not permitted on read replicas; change the parent instead."}
  # Union request body (PostgresPatchConfig oneOf) cannot self-describe
  # an attrs list; declared.
  update_verb :config_merge, route: "config", method: :patch, tombstones: :server_union,
    attrs: %i[pg_config pgbouncer_config]
  update_verb :maintenance_window, route: "set-maintenance-window"
  update_verb :upgrade, route: "upgrade", attrs: %i[version], exclusive: true
  update_verb :rename, macro: :rename, attrs: %i[name],
    order: :last, recovery: :persist_name

  # The tag list is optional; each entry demands key and value.
  attr :tags, classification: :computed_optional, kinds: [:resource]
  attr "tags.key", classification: :required, kinds: [:resource]
  attr "tags.value", classification: :required, kinds: [:resource]
  attr :parent, classification: :computed_optional, kinds: [:resource],
    description: "Parent Postgres database. Give the parent database's name or id. " \
      "The API reports the parent by name, so an imported read replica whose parent is " \
      "configured by id plans a spurious replace; configure parent by name to avoid it."
  # Verb-only attributes: absent from the create body, derivation
  # would mark them computed; declared optional so the maintenance-
  # window verb has plan inputs.
  attr :maintenance_window_days, classification: :computed_optional, kinds: [:resource]
  attr :maintenance_window_start_at, classification: :computed_optional, kinds: [:resource],
    description: "Maintenance window start time. Start hour (0-23). Once set, removing " \
      "this argument keeps the last value; Terraform cannot clear the window (unset it out of band)."

  # Injected attributes: a restore-mode selector no response carries,
  # and the config maps the details read defers to the config verb.
  attr :restore_target, kinds: [:resource], inject: {type: :string, classification: :optional,
                                                     description: "RFC 3339 timestamp of the point in time to restore to, which must fall within " \
      "the source database's backup window [earliest_restore_time, latest_restore_time]. Setting it " \
      "(with parent as the source database) creates this database as a point-in-time restore off the " \
      "parent instead of a fresh database. The restored database is a full primary, not a read " \
      "replica, so it can be resized, HA-changed, and version-upgraded in place. Write-only create " \
      "input: it is not read back from the API, so an imported database shows restore_target unset " \
      "and setting it in config after import forces replacement."}
  attr :pg_config, inject: {type: :map, classification: :computed_optional}, kinds: [:resource]
  attr :pgbouncer_config, inject: {type: :map, classification: :computed_optional}, kinds: [:resource]

  derive_plan_modifiers!

  # Server-moved values, excluded from UseStateForUnknown: targets
  # advance via verbs' side effects; state/hostname/connection_string/
  # fallback_active shift with the cluster; the canonical alias echoes
  # (vm_size, storage_size_gib) trail their user-facing pair.
  moving :state, :hostname, :connection_string, :fallback_active,
    :vm_size, :storage_size_gib,
    :target_server_count, :target_storage_size_gib, :target_version, :target_vm_size

  # tags are read from the API and accepted in config, but no
  # operation sends them: create omits them and the PATCH route that
  # accepts them is not routed. They change server-side only, hence
  # no RequiresReplace.
  updatable :tags

  # parent is a create-mode selector outside the create body; changing
  # it is a different database.
  attr :parent, requires_replace: true, kinds: [:resource]

  # Bespoke parent modifier: the API echoes parent as its canonical
  # path while config holds a name; ParentRefStability (before
  # RequiresReplace) pins matching references so import doesn't force
  # a spurious replace.
  attr :parent, extra_modifiers: [["github.com/ubicloud/terraform-provider-ubicloud/internal/planmodifiers", "planmodifiers.ParentRefStability()"]], kinds: [:resource]

  # Validators the spec cannot express: the version whitelist,
  # parent-exclusive create modes, and the restore point's coupling
  # to parent.
  attr :version, validators: [["github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator", "stringvalidator.OneOf(\n\"16\",\n\"17\",\n\"18\",\n)"]], kinds: [:resource]
  attr :flavor, validators: [["github.com/hashicorp/terraform-plugin-framework/path", "github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator", "stringvalidator.ConflictsWith(path.MatchRoot(\"parent\"))"]], kinds: [:resource]
  attr :private_subnet_name, validators: [["github.com/hashicorp/terraform-plugin-framework/path", "github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator", "stringvalidator.ConflictsWith(path.MatchRoot(\"parent\"))"]], kinds: [:resource]
  attr :restrict_by_default, validators: [["github.com/hashicorp/terraform-plugin-framework/path", "github.com/hashicorp/terraform-plugin-framework-validators/boolvalidator", "boolvalidator.ConflictsWith(path.MatchRoot(\"parent\"))"]], kinds: [:resource]
  attr :parent, validators: [["github.com/ubicloud/terraform-provider-ubicloud/internal/validators", "validators.NotBlank()"]], kinds: [:resource]
  attr :restore_target, validators: [
    ["github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator", "stringvalidator.AlsoRequires(path.MatchRoot(\"parent\"))"],
    ["github.com/ubicloud/terraform-provider-ubicloud/internal/validators", "validators.RFC3339()"],
  ], kinds: [:resource]

  stable_computed :id, :created_at, :flavor

  wait :create, state: "running", timeout: "1800s", poll: "10s"
  wait :delete, timeout: "600s", poll: "10s"
end
