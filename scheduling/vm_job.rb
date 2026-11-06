# frozen_string_literal: true

module Scheduling
  # A placement request splits into shape and allocation rules. Shape, what the
  # VM needs, lives on the VM and its volume rows. Allocation rules, where it may
  # go, live in vm.allocation_rules. Requirements derived from either side are
  # computed here at allocation time.
  module VmJob
    RULE_KEYS = %i[
      allocation_state_filter data_center_exclusion_filter
      distinct_storage_devices family_filter force_host_id
      host_exclusion_filter host_filter location_filter
      location_preference os_filter
    ].freeze

    # Keys accepted by Scheduling::Allocator.allocate, except gpu_count and
    # gpu_device, which are shape. force_host_id is a shortcut that is
    # translated into the other keys before the call.
    ALLOCATOR_KEYS = (RULE_KEYS - [:force_host_id]).freeze

    # VMs created before vm.allocation_rules existed have NULL there and fall
    # back to the strand frame. In the legacy hash, empty arrays and false carry
    # no information, so they are dropped.
    def self.allocator_args(vm, legacy: {}, os_filter: nil)
      stored = vm.allocation_rules
      rules = if stored
        stored.transform_keys(&:to_sym)
      else
        legacy.slice(*RULE_KEYS).compact.reject { |_, value| value == [] || value == false }
      end

      rules[:os_filter] ||= os_filter unless os_filter.nil?
      rules[:family_filter] = ["standard"] if vm.family == "burstable"

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
      merged = force_host(merged) if merged[:force_host_id]
      merged.slice(*ALLOCATOR_KEYS)
    end

    def self.force_host(rules)
      rules.merge(
        allocation_state_filter: [],
        host_filter: [rules[:force_host_id]],
        host_exclusion_filter: [],
        location_filter: [],
        location_preference: [],
        family_filter: [],
      )
    end
    private_class_method :force_host
  end
end
