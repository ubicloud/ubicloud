# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::ReleaseRunnerVmAllocations do
  subject(:rrva) { described_class.new(Strand.new(prog: "Github::ReleaseRunnerVmAllocations")) }

  describe "#wait" do
    it "releases expired held resources and naps for a minute" do
      vm_host = create_vm_host
      vm = create_vm(vm_host_id: vm_host.id, display_state: "deleting")
      allocation = GithubRunnerVmAllocation.create(vm_id: vm.id, label: "ubicloud-standard-2-ubuntu-2404", location_id: vm.location_id, vm_host_id: vm_host.id, created_at: Time.now - 61)

      expect { rrva.wait }.to nap(60)
      expect(allocation).not_to exist
      expect(vm.strand.label).to eq("release_held_allocation")
    end

    it "naps for the configured retention period" do
      allow(Config).to receive(:github_runner_vm_allocation_retention_seconds).and_return(300)
      expect { rrva.wait }.to nap(300)
    end
  end
end
