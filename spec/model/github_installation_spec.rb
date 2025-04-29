# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GithubInstallation do
  subject(:installation) {
    project = Project.create_with_id(name: "default")

    described_class.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")
  }

  it "returns sum of used vm cores" do
    vms = [2, 4, 8].map { create_vm(cores: it) }

    # let's not create runner for the last vm
    vms[..1].each do |vm|
      gr = GithubRunner.create_with_id(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}")
      Strand.create(prog: "Github::RunnerNexus", label: "allocate_vm") { it.id = gr.id }
    end

    expect(installation.total_active_runner_vcpus).to eq(6)
  end

  it "returns sum of used vm cores for arm64" do
    vms = [2, 4].map { create_vm(cores: it, arch: "arm64") }

    vms.each do |vm|
      gr = GithubRunner.create_with_id(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}-arm")
      Strand.create(prog: "Github::RunnerNexus", label: "allocate_vm") { it.id = gr.id }
    end

    expect(installation.total_active_runner_vcpus).to eq(6)
  end

  describe ".free_runner_upgrade?" do
    it "returns nil if it is not set" do
      expect(installation.free_runner_upgrade?).to be_nil
    end

    it "returns false if it is passed" do
      installation.project.set_ff_free_runner_upgrade_until((Time.now - 100).to_s)
      expect(installation.free_runner_upgrade?).to be(false)
    end

    it "returns true if it is from future" do
      installation.project.set_ff_free_runner_upgrade_until((Time.now + 100).to_s)
      expect(installation.free_runner_upgrade?).to be(true)
    end
  end
end
