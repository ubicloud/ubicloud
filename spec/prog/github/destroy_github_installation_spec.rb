# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::DestroyGithubInstallation do
  subject(:dgi) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-github-project") }
  let(:github_installation) {
    GithubInstallation.create(
      name: "ubicloud",
      type: "Organization",
      installation_id: 123,
      project_id: project.id,
    )
  }
  let(:delete_from_github) { true }
  let(:strand) {
    Strand.create_with_id(
      github_installation,
      prog: "Github::DestroyGithubInstallation",
      label: "start",
      stack: [{"delete_from_github" => delete_from_github}],
    )
  }

  let(:repository) do
    repo = GithubRepository.create(installation_id: github_installation.id, name: "ubicloud/ubicloud")
    Strand.create_with_id(repo, prog: "Github::GithubRepositoryNexus", label: "wait")
    repo
  end

  let(:runner) do
    vm = create_vm
    github_runner = GithubRunner.create(
      installation_id: github_installation.id,
      repository_id: repository.id,
      repository_name: repository.name,
      label: "ubicloud",
      vm_id: vm.id,
    )
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "wait")
    github_runner
  end

  let(:aws_location) {
    Location.create(
      name: "github-lifecycle-aws",
      display_name: "github-lifecycle-aws",
      ui_name: "GitHub lifecycle AWS",
      provider: "aws",
      project_id: project.id,
      visible: false,
    )
  }

  let(:aws_private_subnet) do
    subnet = PrivateSubnet.create(
      name: "github-installation-aws",
      net4: "10.30.0.0/16",
      net6: "fd30::/64",
      state: "waiting",
      project_id: project.id,
      location_id: aws_location.id,
      github_installation_id: github_installation.id,
    )
    Strand.create_with_id(subnet, prog: "Vnet::Aws::VpcNexus", label: "wait")
    subnet
  end

  let(:aws_firewall) do
    Firewall.create(
      name: "github-installation-aws-default",
      project_id: project.id,
      location_id: aws_location.id,
      github_installation_id: github_installation.id,
    ).tap { it.associate_with_private_subnet(aws_private_subnet, apply_firewalls: false) }
  end

  describe ".assemble" do
    it "marks the installation deleting, creates one strand, and signals resources" do
      runner

      deletion_strand = nil
      expect {
        deletion_strand = described_class.assemble(github_installation)
      }.to change(Strand, :count).by(1)

      expect(deletion_strand.id).to eq(github_installation.id)
      expect(deletion_strand.stack).to eq([{"delete_from_github" => true}])
      expect(github_installation.reload.state).to eq("deleting")
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "skip_deregistration").count).to eq(1)
    end

    it "returns the existing deletion strand" do
      first_strand = described_class.assemble(github_installation)

      expect {
        expect(described_class.assemble(github_installation, delete_from_github: false)).to eq(first_strand)
      }.not_to change(Strand, :count)
      expect(first_strand.reload.stack).to eq([{"delete_from_github" => true}])
    end

    it "reuses an in-flight strand from the previous stack format" do
      legacy_strand = Strand.create(
        prog: "Github::DestroyGithubInstallation",
        label: "wait_resource_destroy",
        stack: [{"subject_id" => github_installation.id, "deadline_at" => Time.now.iso8601}],
      )

      expect {
        expect(described_class.assemble(github_installation)).to eq(legacy_strand)
      }.not_to change(Strand, :count)
      expect(github_installation.reload.state).to eq("deleting")
    end

    it "rejects an installation with an unrelated strand" do
      Strand.create_with_id(github_installation, prog: "Github::GithubRunnerNexus", label: "start")

      expect {
        described_class.assemble(github_installation)
      }.to raise_error(RuntimeError, "GitHub installation has an unexpected strand")
      expect(github_installation.reload.state).to eq("active")
    end
  end

  describe ".before_run" do
    it "pops if installation already deleted" do
      strand
      github_installation.destroy

      expect { dgi.before_run }.to exit({"msg" => "github installation is destroyed"})
    end

    it "marks an installation deleting for a legacy random-id strand" do
      legacy_strand = Strand.create(
        prog: "Github::DestroyGithubInstallation",
        label: "wait_resource_destroy",
        stack: [{"subject_id" => github_installation.id}],
      )
      legacy_dgi = described_class.new(legacy_strand)

      expect { legacy_dgi.before_run }.to change { github_installation.reload.state }.from("active").to("deleting")
    end

    it "keeps an installation in the deleting state" do
      github_installation.update(state: "deleting")

      expect { dgi.before_run }.not_to change { github_installation.reload.state }
    end
  end

  describe "#start" do
    it "hops after registering deadline" do
      expect { dgi.start }.to hop("delete_installation")
      expect(dgi.strand.stack.first["deadline_at"]).not_to be_nil
    end
  end

  describe "#delete_installation" do
    let(:github_client) { instance_double(Octokit::Client) }

    it "hops after deleting installation from GitHub" do
      expect(Github).to receive(:app_client).once.and_return(github_client)
      expect(github_client).to receive(:delete_installation).once.with(github_installation.installation_id)

      expect { dgi.delete_installation }.to hop("destroy_resources")
    end

    it "hops if the installation is not found on GitHub" do
      expect(Github).to receive(:app_client).once.and_return(github_client)
      expect(github_client).to receive(:delete_installation).once.with(github_installation.installation_id).and_raise(Octokit::NotFound)

      expect { dgi.delete_installation }.to hop("destroy_resources")
    end

    context "when GitHub already deleted the installation" do
      let(:delete_from_github) { false }

      it "does not call GitHub" do
        expect(Github).not_to receive(:app_client)

        expect { dgi.delete_installation }.to hop("destroy_resources")
      end
    end
  end

  describe "#destroy_resources" do
    it "signals repositories and runners" do
      runner

      expect { dgi.destroy_resources }.to hop("wait_resource_destroy")
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "skip_deregistration").count).to eq(1)
    end
  end

  describe "#wait_resource_destroy" do
    it "resignals and naps while a runner exists" do
      runner

      expect { dgi.wait_resource_destroy }.to nap(10)
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: runner.id, name: "skip_deregistration").count).to eq(1)
    end

    it "resignals and naps while a repository exists" do
      repository

      expect { dgi.wait_resource_destroy }.to nap(10)
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
    end

    it "destroys the firewall and signals the shared subnet" do
      firewall_id = aws_firewall.id
      subnet_id = aws_private_subnet.id

      expect { dgi.wait_resource_destroy }.to hop("wait_network_destroy")
      expect(Firewall[firewall_id]).to be_nil
      expect(PrivateSubnet[subnet_id]).not_to be_nil
      expect(PrivateSubnet[subnet_id].destroy_set?).to be(true)
      expect(GithubInstallation[github_installation.id]).not_to be_nil
    end

    it "does not duplicate an existing shared subnet destroy signal" do
      firewall_id = aws_firewall.id
      aws_private_subnet.incr_destroy

      expect { dgi.wait_resource_destroy }.to hop("wait_network_destroy")
      expect(Firewall[firewall_id]).to be_nil
      expect(Semaphore.where(strand_id: aws_private_subnet.id, name: "destroy").count).to eq(1)
    end

    it "deletes the installation if it has no shared network" do
      installation_id = github_installation.id
      GithubCustomLabel.create(installation_id:, name: "custom-label", alias_for: "ubicloud-standard-2")
      expect(Clog).to receive(:emit).with("GithubInstallation is deleted.", instance_of(GithubInstallation)).and_call_original

      expect { dgi.wait_resource_destroy }.to exit({"msg" => "github installation destroyed"})
      expect(GithubInstallation[installation_id]).to be_nil
    end
  end

  describe "#wait_network_destroy" do
    it "signals and naps while the shared subnet exists" do
      subnet_id = aws_private_subnet.id

      expect { dgi.wait_network_destroy }.to nap(10)
      expect(PrivateSubnet[subnet_id].destroy_set?).to be(true)
    end

    it "does not duplicate the destroy semaphore" do
      aws_private_subnet.incr_destroy

      expect { dgi.wait_network_destroy }.to nap(10)
      expect(Semaphore.where(strand_id: aws_private_subnet.id, name: "destroy").count).to eq(1)
    end

    it "deletes the installation after the shared subnet is gone" do
      installation_id = github_installation.id
      aws_private_subnet.destroy
      expect(Clog).to receive(:emit).with("GithubInstallation is deleted.", instance_of(GithubInstallation)).and_call_original

      expect { dgi.wait_network_destroy }.to exit({"msg" => "github installation destroyed"})
      expect(GithubInstallation[installation_id]).to be_nil
    end
  end
end
