# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Scheduling::RunnerSpiller do
  subject(:spiller) { described_class.new }

  let(:runner_project) { Project.create(name: "runner-service") }
  let(:now) { Time.now }
  let(:installation) { create_installation }

  def create_installation(spill: true)
    project = Project.create(name: "customer")
    project.set_ff_spill_to_alien_runners(spill)
    GithubInstallation.create(installation_id: GithubInstallation.count + 1, project_id: project.id, name: "ubicloud", type: "Organization")
  end

  def create_runner(label, waited:, installation: self.installation, boot_image: "github-ubuntu-2204")
    vcpus = Github.runner_labels[label]["vcpus"]
    vm = create_vm(location_id: Location::GITHUB_RUNNERS_ID, project_id: runner_project.id, name: "vm#{Vm.count}", vcpus:, boot_image:, created_at: now - waited)
    runner = GithubRunner.create(installation_id: installation.id, vm_id: vm.id, location_id: Location::GITHUB_RUNNERS_ID, repository_name: "test-repo", label:)
    Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait_vm")
    runner
  end

  def spilled(runners)
    runners.select(&:spill_over_set?)
  end

  it "spills the longest waiting runners first, then the largest" do
    small = create_runner("ubicloud-standard-2", waited: 100)
    large = create_runner("ubicloud-standard-16", waited: 100)
    recent = create_runner("ubicloud-standard-30", waited: 50)
    expect(Config).to receive(:github_runner_aws_spill_runner_capacity).and_return(2)

    spiller.spill([small, large, recent].map(&:vm_id))
    expect(spilled([small, large, recent])).to eq([small, large])
  end

  it "does not spill runners that cannot spill" do
    runners = [
      create_runner("ubicloud-standard-2", waited: 10),
      create_runner("ubicloud-standard-60", waited: 100),
      create_runner("ubicloud-standard-2", waited: 100, installation: create_installation(spill: false)),
    ]

    spiller.spill(runners.map(&:vm_id))
    expect(spilled(runners)).to be_empty
  end

  it "does not spill runners whose project has no alien quota left" do
    installation.project.update(reputation: "limited")
    location = Location.create(name: "eu-central-1", provider: "aws", project_id: runner_project.id, display_name: "aws-eu-central-1", ui_name: "AWS Frankfurt", visible: true)
    expect(Config).to receive(:github_runner_aws_location_id).and_return(location.id).at_least(:once)
    aws_vm = create_vm(location_id: location.id, name: "aws-vm")
    aws_runner = GithubRunner.create(installation_id: installation.id, vm_id: aws_vm.id, location_id: location.id, repository_name: "test-repo", label: "ubicloud-standard-2")
    Strand.create_with_id(aws_runner, prog: "Github::GithubRunnerNexus", label: "wait")
    runner = create_runner("ubicloud-standard-2", waited: 100)

    spiller.spill([runner.vm_id])
    expect(runner.spill_over_set?).to be(false)
  end

  it "keeps the spills within the vcpu capacity" do
    largest = create_runner("ubicloud-standard-30", waited: 100)
    large = create_runner("ubicloud-standard-16", waited: 100)
    small = create_runner("ubicloud-standard-2", waited: 100)
    expect(Config).to receive(:github_runner_aws_spill_vcpu_capacity).and_return(40).twice
    expect(Config).to receive(:central_vm_scheduler_spill_installation_share).and_return(1.0)

    spiller.spill([largest, large, small].map(&:vm_id))
    expect(spilled([largest, large, small])).to eq([largest, small])
  end

  it "keeps the spills of an installation within its share of the vcpu capacity" do
    create_runner("ubicloud-standard-30", waited: 100, boot_image: Config.github_ubuntu_2204_x64_aws_ami_version)
    first, second = Array.new(2) { create_runner("ubicloud-standard-16", waited: 100) }
    other = create_runner("ubicloud-standard-16", waited: 100, installation: create_installation)
    expect(Clog).to receive(:emit).with("central vm scheduler spilled runner", hash_including(:central_vm_scheduler_spill)).twice.and_call_original

    spiller.spill([first, second, other].map(&:vm_id))
    expect(spilled([first, second, other]).size).to eq(2)
    expect(other.spill_over_set?).to be(true)
  end
end
