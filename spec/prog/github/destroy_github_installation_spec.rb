# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::DestroyGithubInstallation do
  subject(:dgi) {
    st = Strand.create(prog: "Github::DestroyGithubInstallation", label: "start", stack: [{"subject_id" => github_installation.id}])
    described_class.new(st)
  }

  let(:project) { Project.create(name: "test-github-project") }
  let(:github_installation) {
    GithubInstallation.create(
      name: "ubicloud",
      type: "Organization",
      installation_id: 123,
      project_id: project.id
    )
  }

  let(:repository) do
    repo = GithubRepository.create(installation_id: github_installation.id, name: "ubicloud/ubicloud")
    Strand.create_with_id(repo, prog: "Github::GithubRepositoryNexus", label: "wait")
    repo
  end

  let(:runner) do
    vm = create_vm
    runner = GithubRunner.create(
      installation_id: github_installation.id,
      repository_id: repository.id,
      repository_name: repository.name,
      label: "ubicloud",
      vm_id: vm.id
    )
    Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait")
    runner
  end

  describe ".assemble" do
    it "creates a strand" do
      expect { described_class.assemble(github_installation) }.to change(Strand, :count).from(0).to(1)
    end
  end

  describe ".before_run" do
    it "pops if installation already deleted" do
      github_installation.destroy
      expect { dgi.before_run }.to exit({"msg" => "github installation is destroyed"})
    end

    it "no ops if installation exists" do
      # Real github_installation exists, so before_run should not exit
      expect { dgi.before_run }.not_to raise_error
    end
  end

  describe "#start" do
    it "hops after registering deadline" do
      expect { dgi.start }.to hop("delete_installation")
      expect(dgi.strand.stack.first["deadline_at"]).not_to be_nil
    end
  end

  describe "#delete_installation" do
    before do
      allow(Github).to receive(:app_client).and_return(instance_double(Octokit::Client))
    end

    it "hops after deleting installation from GitHub" do
      expect(Github.app_client).to receive(:delete_installation).with(github_installation.installation_id)
      expect { dgi.delete_installation }.to hop("destroy_resources")
    end

    it "hops if even the installation not found" do
      expect(Github.app_client).to receive(:delete_installation).with(github_installation.installation_id).and_raise(Octokit::NotFound)
      expect { dgi.delete_installation }.to hop("destroy_resources")
    end
  end

  describe "#destroy_resources" do
    it "hops after incrementing destroy for repositories and runners" do
      runner
      expect { dgi.destroy_resources }.to hop("wait_resource_destroy")

      # Verify semaphores were created
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "skip_deregistration").count).to eq(1)
    end
  end

  describe "#wait_resource_destroy" do
    it "naps if not all runners destroyed" do
      runner
      expect { dgi.wait_resource_destroy }.to nap(10)
    end

    it "naps if not all repositories destroyed" do
      repository
      # No runners, but repository exists
      expect { dgi.wait_resource_destroy }.to nap(10)
    end

    it "deletes resource and pops" do
      # No repositories or runners - installation can be destroyed
      installation_id = github_installation.id
      expect { dgi.wait_resource_destroy }.to exit({"msg" => "github installation destroyed"})
      expect(GithubInstallation[installation_id]).to be_nil
    end
  end
end
