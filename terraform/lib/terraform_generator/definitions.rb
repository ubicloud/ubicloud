# frozen_string_literal: true

# The terraform types the provider offers. Everything about them is derived
# from openapi/openapi.yml; an entry states only the order of update verbs,
# where that order matters.
module TerraformGenerator::Definitions
  TYPES = {}.freeze

  # The keys an entry may have. order names verbs that run before the
  # others, in that order.
  KEYS = %i[order].freeze
end
