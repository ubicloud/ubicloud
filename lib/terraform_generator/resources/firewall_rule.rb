# frozen_string_literal: true

TerraformGenerator.resource :firewall_rule do
  # Creates on the parent firewall's collection; details nest a level
  # deeper than the default path shape.
  create_sample "/project/x/location/y/firewall/z/firewall-rule"
  details_sample "/project/x/location/y/firewall/z/firewall-rule/w"

  key_attrs firewall_reference: :firewall_reference, firewall_rule_id: :id

  # Port-range spelling: reads keep the user's form when it normalizes
  # to the API's canonical value; writes send canonical (hand helpers
  # in port_range.go, test-covered).
  attr :port_range, wrap_read: "normalizedPortRange", wrap_write: "normalizePortRange", kinds: [:resource]
  # The one true argument, demanded at plan time.
  attr :cidr, classification: :required, kinds: [:resource]
  # The parent's id duplicates the path key; firewall_reference is the
  # handle.
  omit :firewall_id, kinds: [:resource]
end
