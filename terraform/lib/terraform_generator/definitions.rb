# frozen_string_literal: true

# The terraform types the provider offers. Everything about them is derived
# from openapi/openapi.yml; an entry states only the order of update verbs,
# where that order matters.
module TerraformGenerator::Definitions
  TYPES = {
    firewall: {},
    firewall_rule: {},
    inference_api_key: {},
    load_balancer: {},
    private_subnet: {},
    project: {},
    ssh_public_key: {},
    vm: {},
  }.freeze

  # The keys an entry may have. order names verbs that run before the
  # others, in that order.
  KEYS = %i[order].freeze
end
