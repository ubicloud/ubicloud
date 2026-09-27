# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe EmberPool do
  let(:pool) { create_ember_pool }

  # A blank is restored from a template and a template is for one workload,
  # so a location has one pool per workload rather than one pool.
  it "is one per location and workload" do
    pool
    expect { create_ember_pool }.to raise_error(Sequel::ValidationFailed, /is already taken/)
    expect { create_ember_pool(workload: "runner") }.not_to raise_error
  end

  it "has its own ubid type" do
    expect(pool.ubid).to start_with("cp")
  end

  describe "#blanks_held" do
    it "adds up the blanks waiting on its hosts" do
      add_ember_blanks(create_ember_host, 2)
      add_ember_blanks(create_ember_host, 3)
      expect(pool.blanks_held).to eq(5)
    end

    it "ignores hosts that are drained" do
      add_ember_blanks(create_ember_host(allocation_state: "draining"), 2)
      expect(pool.blanks_held).to eq(0)
    end

    it "ignores hosts in other locations" do
      add_ember_blanks(create_ember_host(vm_host: create_vm_host(location_id: Location::HETZNER_HEL1_ID)), 9)
      expect(pool.blanks_held).to eq(0)
    end
  end
end
