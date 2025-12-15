# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::DestroyGithubInstallation do
  subject(:dgi) {
    described_class.new(Strand.new).tap {
      it.instance_variable_set(:@github_installation, github_installation)
    }
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

  # Helper to create GithubRepository with Strand
  def create_test_repository(name: "test-repo")
    id = GithubRepository.generate_uuid
    repo = GithubRepository.create_with_id(id, installation_id: github_installation.id, name: name)
    Strand.create_with_id(id, prog: "Github::GithubRepositoryNexus", label: "wait")
    repo
  end

  # Helper to create GithubRunner with Strand and VM
  def create_test_runner(repository:)
    vm = create_vm
    id = GithubRunner.generate_uuid
    runner = GithubRunner.create_with_id(
      id,
      installation_id: github_installation.id,
      repository_id: repository.id,
      repository_name: repository.name,
      label: "ubicloud",
      vm_id: vm.id
    )
    Strand.create_with_id(id, prog: "Github::GithubRunnerNexus", label: "wait")
    runner
  end

  describe ".assemble" do
    it "creates a strand" do
      expect { described_class.assemble(github_installation) }.to change(Strand, :count).from(0).to(1)
    end
  end

  describe ".before_run" do
    it "pops if installation already deleted" do
      expect(dgi).to receive(:github_installation).and_return(nil)
      expect { dgi.before_run }.to exit({"msg" => "github installation is destroyed"})
    end

    it "no ops if installation exists" do
      # Real github_installation exists, so before_run should not exit
      expect { dgi.before_run }.not_to raise_error
    end
  end

  describe "#start" do
    it "hops after registering deadline" do
      expect(dgi).to receive(:register_deadline)
      expect { dgi.start }.to hop("delete_installation")
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
      repository = create_test_repository
      runner = create_test_runner(repository: repository)

      expect { dgi.destroy_resources }.to hop("wait_resource_destroy")

      # Verify semaphores were created
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "skip_deregistration").count).to eq(1)
    end
  end

  describe "#wait_resource_destroy" do
    it "naps if not all runners destroyed" do
      repository = create_test_repository
      create_test_runner(repository: repository)
      expect { dgi.wait_resource_destroy }.to nap(10)
    end

    it "naps if not all repositories destroyed" do
      create_test_repository
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
