# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Scheduling::VmJob do
  let(:location_id) { Location.generate_uuid }
  let(:vm) { Vm.new(family: "standard", location_id:, allocation_rules: {}) }
  let(:base) do
    {
      allocation_state_filter: ["accepting"],
      data_center_exclusion_filter: [],
      distinct_storage_devices: false,
      family_filter: ["standard"],
      host_exclusion_filter: [],
      host_filter: [],
      location_filter: [location_id],
      location_preference: [],
      os_filter: nil,
    }
  end

  describe ".allocator_args" do
    it "exposes the allocator filter keys" do
      expect(described_class::ALLOCATOR_KEYS).to match_array(%i[
        allocation_state_filter data_center_exclusion_filter
        distinct_storage_devices family_filter host_exclusion_filter
        host_filter location_filter location_preference os_filter
      ])
    end

    it "defaults to the location and family of the vm" do
      expect(described_class.allocator_args(vm)).to eq(base)
    end

    it "reads rules from the column" do
      vm.allocation_rules = {"location_filter" => ["loc2"]}

      expect(described_class.allocator_args(vm)).to eq(
        base.merge(location_filter: ["loc2"]),
      )
    end

    it "turns a forced host into a host filter" do
      vm.allocation_rules = {"force_host_id" => "vh1"}

      expect(described_class.allocator_args(vm)).to eq(
        base.merge(
          allocation_state_filter: [],
          host_filter: ["vh1"],
          location_filter: [],
          family_filter: [],
        ),
      )
    end

    it "keeps the host exclusions of a forced host" do
      vm.allocation_rules = {"force_host_id" => "vh1", "host_exclusion_filter" => ["vh2"]}

      expect(described_class.allocator_args(vm)).to eq(
        base.merge(
          allocation_state_filter: [],
          host_filter: ["vh1"],
          host_exclusion_filter: ["vh2"],
          location_filter: [],
          family_filter: [],
        ),
      )
    end

    it "derives the OS filter when the rules do not set one" do
      expect(described_class.allocator_args(vm, os_filter: ["ubuntu-24.04"])).to eq(
        base.merge(os_filter: ["ubuntu-24.04"]),
      )
    end

    it "keeps the OS filter of the rules" do
      vm.allocation_rules = {"os_filter" => ["ubuntu-22.04"]}

      expect(described_class.allocator_args(vm, os_filter: ["ubuntu-24.04"])).to eq(
        base.merge(os_filter: ["ubuntu-22.04"]),
      )
    end

    it "forces the standard family filter for burstable VMs" do
      vm.family = "burstable"

      expect(described_class.allocator_args(vm)).to eq(base)
    end

    it "keeps the standard family filter for burstable VMs on a forced host" do
      vm.family = "burstable"
      vm.allocation_rules = {"force_host_id" => "vh1"}

      expect(described_class.allocator_args(vm)).to eq(
        base.merge(
          allocation_state_filter: [],
          host_filter: ["vh1"],
          location_filter: [],
        ),
      )
    end
  end

  describe ".differing_request_fields" do
    let(:request) do
      Scheduling::Allocator::Request.new.tap do |r|
        r.location_filter = ["a", "b"]
        r.os_filter = nil
        r.target_host_utilization = 0.55
      end
    end

    def request_with(**fields)
      request.dup.tap { |r| fields.each { |field, value| r[field] = value } }
    end

    it "is empty for equal requests" do
      expect(described_class.differing_request_fields(request, request.dup)).to eq({})
    end

    it "ignores the order of unordered fields" do
      other = request_with(location_filter: ["b", "a"])

      expect(described_class.differing_request_fields(request, other)).to eq({})
    end

    it "reports the fields that differ with both values" do
      other = request_with(location_filter: ["a"], target_host_utilization: 0.65, os_filter: ["x"])

      expect(described_class.differing_request_fields(request, other)).to eq(
        location_filter: [["a", "b"], ["a"]],
        target_host_utilization: [0.55, 0.65],
        os_filter: [nil, ["x"]],
      )
    end
  end
end
