# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GithubInstallation do
  subject(:installation) {
    project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }

    described_class.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")
  }

  it "returns sum of used vm cores" do
    vms = [2, 4, 8].map do |core_count|
      Vm.create_with_id(display_state: "running", unix_user: "x", public_key: "x", name: "x", family: "standard", cores: core_count, location: "x", boot_image: "x")
    end

    # let's not create runner for the last vm
    vms[..1].each do |vm|
      gr = GithubRunner.create_with_id(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}")
      Strand.create(prog: "Github::RunnerNexus", label: "allocate_vm") { _1.id = gr.id }
    end

    expect(installation.total_active_runner_cores).to eq(6)
  end
end
