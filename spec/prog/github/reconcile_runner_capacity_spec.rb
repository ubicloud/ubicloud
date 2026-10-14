# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::ReconcileRunnerCapacity do
  subject(:nx) { described_class.new(Strand.new(prog: "Github::ReconcileRunnerCapacity")) }

  describe "#wait" do
    it "adopts runners, reconciles the capacity counters and naps" do
      create_vm_host(location_id: Location::GITHUB_RUNNERS_ID, total_cores: 48, total_cpus: 96, total_hugepages_1g: 375)
      vm = create_vm(location_id: Location::GITHUB_RUNNERS_ID)
      installation = GithubInstallation.create(installation_id: 790, name: "reconcile", type: "User")
      runner = GithubRunner.create(installation_id: installation.id, repository_name: "test-repo", label: "ubicloud-standard-4", vm_id: vm.id, location_id: vm.location_id)
      Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait")

      expect { nx.wait }.to nap(600)
      expect(runner.reload.capacity_pool).to eq("x64-standard")
      expect(GithubRunnerCapacity["x64-standard"].values.values_at(:total_cores, :total_hugepages_1g, :used_cores, :used_hugepages_1g)).to eq([48, 375, 2, 16])
    end
  end
end
