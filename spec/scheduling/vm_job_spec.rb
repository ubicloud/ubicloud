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

  it "exposes the allocator filter keys" do
    expect(described_class::ALLOCATOR_KEYS).to match_array(%i[
      allocation_state_filter data_center_exclusion_filter
      distinct_storage_devices family_filter host_exclusion_filter
      host_filter location_filter location_preference os_filter
    ])
  end

  it "reads rules from the column" do
    vm.allocation_rules = {"location_filter" => ["loc2"]}

    expect(described_class.allocator_args(vm)).to eq(
      base.merge(location_filter: ["loc2"]),
    )
  end

  it "defaults to the location and family of the vm" do
    expect(described_class.allocator_args(vm)).to eq(base)
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
