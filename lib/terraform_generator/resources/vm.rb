# frozen_string_literal: true

TerraformGenerator.resource :vm do
  # No serializer fixture: vm assembly is heavyweight; committee
  # validation and the end-to-end harness carry the schema trust.
  route "vm"

  # Immutable attrs plan replacements instead of doomed updates;
  # computeds pin instead of "(known after apply)".
  derive_plan_modifiers!

  # Details-response names the resource schema renamed (datasource
  # kept the API spellings).
  attr :ip4_enabled, tf: :enable_ip4, kinds: [:resource]
  attr :storage_size_gib, tf: :storage_size, kinds: [:resource]

  # Response-only fields the published resource schema does not
  # carry, id included; the datasource exposes them.
  omit :id, :ip4, :ip6, :private_ipv4, :private_ipv6, :state, :subnet, :firewalls,
    kinds: [:resource]

  # Create-side inputs the published datasource does not carry:
  # echoed on details, resource-only in terraform.
  omit :boot_image, :gpu, :ip4_enabled, kinds: [:datasource]

  # Write-only per the spec, yet published as computed_optional; plain
  # optional is the natural derivation, but changing it now would alter
  # the schema under existing configurations.
  attr :init_script, classification: :computed_optional, kinds: [:resource]

  # The nested rule listing matches firewall's datasource shape.
  omit "firewalls.firewall_rules.protocol", "firewalls.firewall_rules.description",
    kinds: [:datasource]
end
