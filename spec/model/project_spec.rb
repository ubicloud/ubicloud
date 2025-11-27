# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Project do
  subject(:project) { described_class.create(name: "test") }

  describe "#validate" do
    invalid_name = "must be less than 64 characters and only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"

    it "validates that name for new object is not empty and has correct format" do
      project = described_class.new
      expect(project.valid?).to be false
      expect(project.errors[:name]).to eq(["is not present", invalid_name])

      project.name = "@"
      expect(project.valid?).to be false
      expect(project.errors[:name]).to eq([invalid_name])

      project.name = "a"
      expect(project.valid?).to be true

      project.name = "a-"
      expect(project.valid?).to be false
      expect(project.errors[:name]).to eq([invalid_name])

      project.name = "a-b"
      expect(project.valid?).to be true

      project.name = "a-#{"b" * 63}"
      expect(project.valid?).to be false
      expect(project.errors[:name]).to eq([invalid_name])
    end

    it "validates that name for existing object is valid if the name has changed" do
      expect(project.valid?).to be true

      project.name = "-"
      expect(project.valid?).to be false
      expect(project.errors[:name]).to eq([invalid_name])

      project.name = "a"
      expect(project.valid?).to be true

      project.name = "@"
      expect(project.valid?).to be false
      expect(project.errors[:name]).to eq([invalid_name])
    end
  end

  describe ".has_valid_payment_method?" do
    it "returns true when Stripe not enabled" do
      expect(Config).to receive(:stripe_secret_key).and_return(nil)
      expect(project.has_valid_payment_method?).to be true
    end

    it "returns true when discount is 100" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      project.discount = 100
      expect(project.has_valid_payment_method?).to be true
    end

    it "returns false when no billing info" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns false when no payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = BillingInfo.create(stripe_id: "cus")
      project.update(billing_info_id: bi.id)
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns true when has valid payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = BillingInfo.create(stripe_id: "cus123")
      PaymentMethod.create(billing_info_id: bi.id, stripe_id: "pm123")
      project.update(billing_info_id: bi.id)
      expect(project.has_valid_payment_method?).to be true
    end

    it "returns true when has some credits" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = BillingInfo.create(stripe_id: "cus")
      project.update(billing_info_id: bi.id, credit: 100)
      expect(project.has_valid_payment_method?).to be true
    end
  end

  describe ".soft_delete" do
    it "deletes github installations" do
      SubjectTag.create(project_id: project.id, name: "test").add_subject(project.id)
      AccessControlEntry.new_with_id(project_id: project.id, subject_id: project.id).save_changes(validate: false)
      expect(project).to receive(:github_installations).and_return([instance_double(GithubInstallation)])
      expect(Prog::Github::DestroyGithubInstallation).to receive(:assemble)
      expect(project).to receive(:update).with(visible: false)
      project.soft_delete
      expect(SubjectTag.all).to be_empty
      expect(AccessControlEntry.all).to be_empty
    end
  end

  describe ".active?" do
    it "returns false if it's soft deleted" do
      expect(project).to receive(:visible).and_return(false)
      expect(project.active?).to be false
    end

    it "returns false if any accounts is suspended" do
      project = described_class.create(name: "test")
      Account.create(email: "user1@example.com").tap { it.add_project(project) }
      Account.create(email: "user2@example.com").tap { it.add_project(project) }.update(suspended_at: Time.now)
      expect(project.active?).to be false
    end

    it "returns true if any condition not match" do
      project = described_class.create(name: "test")
      Account.create(email: "user1@example.com").tap { it.add_project(project) }
      expect(project.active?).to be true
    end
  end

  describe ".default_location" do
    it "returns the location with the highest available core capacity" do
      [
        {allocation_state: "accepting", location_id: Location::HETZNER_FSN1_ID, total_cores: 10, used_cores: 3},
        {allocation_state: "accepting", location_id: Location::HETZNER_FSN1_ID, total_cores: 10, used_cores: 3},
        {allocation_state: "accepting", location_id: Location::HETZNER_FSN1_ID, total_cores: 10, used_cores: 1},
        {allocation_state: "accepting", location_id: Location::LEASEWEB_WDC02_ID, total_cores: 100, used_cores: 99},
        {allocation_state: "draining", location_id: Location::HETZNER_HEL1_ID, total_cores: 100, used_cores: 0},
        {allocation_state: "accepting", location_id: Location::GITHUB_RUNNERS_ID, total_cores: 100, used_cores: 0}
      ].each { create_vm_host(**it) }

      expect(project.default_location).to eq("github-runners")
    end

    it "provides first location when location with highest available core capacity cannot be determined" do
      expect(project.default_location).to eq "eu-central-h1"
    end
  end

  it "sets and gets feature flags" do
    mod = Module.new
    described_class.feature_flag(:dummy_flag1, :dummy_flag2, into: mod)
    project = described_class.create(name: "dummy-name", feature_flags: {"dummy_flag2" => "val2", "not_exists_flag" => "no"})
    project.extend(mod)

    expect(project.get_ff_dummy_flag1).to be_nil
    expect(project.get_ff_dummy_flag2).to eq("val2")
    expect(project.feature_flags).to have_key("not_exists_flag")
    project.set_ff_dummy_flag1("new-value")
    expect(project.get_ff_dummy_flag1).to eq("new-value")
    expect(project.get_ff_dummy_flag2).to eq("val2")
    expect(project.feature_flags).not_to have_key("not_exists_flag")
  end

  it "calculates current resource usage" do
    expect(project.current_resource_usage("VmVCpu")).to eq 0
    vm1 = Prog::Vm::Nexus.assemble("a a", project.id).subject
    expect(project.current_resource_usage("VmVCpu")).to eq 2
    Prog::Vm::Nexus.assemble("a a", project.id, size: "standard-4")
    expect(project.current_resource_usage("VmVCpu")).to eq 6

    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 0
    gi = GithubInstallation.create(installation_id: 1, name: "a", project_id: project.id, type: "a")
    gr = gi.add_runner(label: "ubicloud", repository_name: "a/a")
    gr.update(vm_id: vm1.id)
    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 0
    grst = Strand.new(id: gr.id, label: "start", prog: "Prog::Github::GithubRunnerNexus")
    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 0
    grst.update(label: "wait_vm")
    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 2
    gr2 = gi.add_runner(label: "ubicloud-standard-60", repository_name: "a/a")
    grst2 = Strand.new(id: gr2.id, label: "wait_concurrency_limit", prog: "Prog::Github::GithubRunnerNexus")
    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 2
    grst2.update(label: "wait_vm")
    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 62

    expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
    expect(project.current_resource_usage("PostgresVCpu")).to eq 0
    Prog::Postgres::PostgresResourceNexus.assemble(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "a", target_vm_size: "standard-2", target_storage_size_gib: 64)
    expect(project.current_resource_usage("PostgresVCpu")).to eq 2
    Prog::Postgres::PostgresResourceNexus.assemble(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "b", target_vm_size: "standard-4", target_storage_size_gib: 128)
    expect(project.current_resource_usage("PostgresVCpu")).to eq 6

    expect(Config).to receive(:kubernetes_service_project_id).and_return(project.id).at_least(:once)
    expect(project.current_resource_usage("KubernetesVCpu")).to eq 0
    cluster = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "a", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 1).subject
    Prog::Kubernetes::KubernetesNodeNexus.assemble(project.id, sshable_unix_user: "ubi", name: "cp-node", location_id: cluster.location.id, size: cluster.target_node_size, storage_volumes: [{encrypted: true, size_gib: cluster.target_node_storage_size_gib}], boot_image: "kubernetes-#{cluster.version.tr(".", "_")}", private_subnet_id: cluster.private_subnet_id, enable_ip4: true, kubernetes_cluster_id: cluster.id).subject
    expect(project.current_resource_usage("KubernetesVCpu")).to eq 2
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "a-np", node_count: 3, kubernetes_cluster_id: cluster.id, target_node_size: "standard-4").subject
    expect(project.current_resource_usage("KubernetesVCpu")).to eq 14

    expect { project.current_resource_usage("UnknownResource") }.to raise_error(RuntimeError)
  end

  it "calculates effective quota value" do
    project = described_class.create(name: "test")
    project.add_quota(ProjectQuota.new(value: 1000).tap { it.quota_id = "14fa6820-bf63-41d2-b35e-4a4dcefd1b15" })
    expect(project.effective_quota_value("VmVCpu")).to eq 32
    expect(project.effective_quota_value("GithubRunnerVCpu")).to eq 1000
    expect(project.effective_quota_value("PostgresVCpu")).to eq 128

    expect(project).to receive(:reputation).and_return("verified").at_least(:once)
    expect(project.effective_quota_value("VmVCpu")).to eq 256
    expect(project.effective_quota_value("GithubRunnerVCpu")).to eq 1000
    expect(project.effective_quota_value("PostgresVCpu")).to eq 256
  end

  it "checks if quota is available" do
    expect(project).to receive(:current_resource_usage).and_return(10).twice
    expect(project).to receive(:effective_quota_value).and_return(20).twice
    expect(project.quota_available?("VmVCpu", 5)).to be true
    expect(project.quota_available?("VmVCpu", 20)).to be false
  end
end
