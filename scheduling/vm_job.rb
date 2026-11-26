# frozen_string_literal: true

module Scheduling
  module VmJob
    RULE_KEYS = %i[
      allocation_state_filter data_center_exclusion_filter
      distinct_storage_devices family_filter force_host_id
      host_exclusion_filter host_filter location_filter
      location_preference os_filter
    ].freeze

    # force_host_id is translated into the other keys before the call.
    ALLOCATOR_KEYS = (RULE_KEYS - [:force_host_id]).freeze

    # The vm must have stored allocation rules.
    def self.allocator_args(vm, os_filter: nil)
      rules = vm.allocation_rules.transform_keys(&:to_sym)
      rules[:os_filter] ||= os_filter unless os_filter.nil?

      merged = {
        allocation_state_filter: ["accepting"],
        data_center_exclusion_filter: [],
        distinct_storage_devices: false,
        family_filter: [vm.family],
        host_exclusion_filter: [],
        host_filter: [],
        location_filter: [vm.location_id],
        location_preference: [],
        os_filter: nil,
      }.merge(rules)
      if merged[:force_host_id]
        merged.merge!(
          allocation_state_filter: [],
          host_filter: [merged[:force_host_id]],
          location_filter: [],
          location_preference: [],
          family_filter: [],
        )
      end
      merged[:family_filter] = ["standard"] if vm.family == "burstable"
      merged.slice(*ALLOCATOR_KEYS)
    end
  end
end
