# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GithubInstallation do
  subject(:installation) {
    described_class.create(installation_id: 123, project_id: Project.create(name: "default").id, name: "test-user", type: "User")
  }

  it "returns sum of used vm cores" do
    vms = [2, 4, 8].map { create_vm(cores: it) }

    # let's not create runner for the last vm
    vms[..1].each do |vm|
      gr = GithubRunner.create(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}")
      Strand.create(prog: "Github::RunnerNexus", label: "allocate_vm") { it.id = gr.id }
    end

    expect(installation.total_active_runner_vcpus).to eq(6)
  end

  it "returns sum of used vm cores for arm64" do
    vms = [2, 4].map { create_vm(cores: it, arch: "arm64") }

    vms.each do |vm|
      gr = GithubRunner.create(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}-arm")
      Strand.create(prog: "Github::RunnerNexus", label: "allocate_vm") { it.id = gr.id }
    end

    expect(installation.total_active_runner_vcpus).to eq(6)
  end

  describe "#cache_storage_gib" do
    it "returns effective quota if the premium is not enabled" do
      expect(installation.cache_storage_gib).to eq(30)
    end

    it "returns 100GB if the premium is enabled" do
      installation.update(allocator_preferences: {"family_filter" => ["standard", "premium"]})
      expect(installation.cache_storage_gib).to eq(100)
    end

    it "returns effective quota if it is larger than premium" do
      installation.update(allocator_preferences: {"family_filter" => ["standard", "premium"]})
      installation.project.add_quota(quota_id: ProjectQuota.default_quotas["GithubRunnerCacheStorage"]["id"], value: 300)
      expect(installation.cache_storage_gib).to eq(300)
    end
  end
end
