# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Project do
  subject(:project) { described_class.create_with_id(name: "test") }

  describe "#validate" do
    invalid_name = "must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"

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

    it "returns false when no billing info" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns false when no payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = BillingInfo.create_with_id(stripe_id: "cus")
      project.update(billing_info_id: bi.id)
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns true when has valid payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = BillingInfo.create_with_id(stripe_id: "cus123")
      PaymentMethod.create_with_id(billing_info_id: bi.id, stripe_id: "pm123")
      project.update(billing_info_id: bi.id)
      expect(project.has_valid_payment_method?).to be true
    end

    it "returns true when has some credits" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = BillingInfo.create_with_id(stripe_id: "cus")
      project.update(billing_info_id: bi.id, credit: 100)
      expect(project.has_valid_payment_method?).to be true
    end

    it "sets and gets feature flags" do
      mod = Module.new
      described_class.feature_flag(:dummy_flag, into: mod)
      project = described_class.create_with_id(name: "dummy-name")
      project.extend(mod)

      expect(project.get_ff_dummy_flag).to be_nil
      project.set_ff_dummy_flag("new-value")
      expect(project.get_ff_dummy_flag).to eq "new-value"
    end
  end

  describe ".soft_delete" do
    it "deletes github installations" do
      SubjectTag.create_with_id(project_id: project.id, name: "test").add_subject(project.id)
      AccessControlEntry.new_with_id(project_id: project.id, subject_id: project.id).save_changes(validate: false)
      expect(project).to receive(:access_tags_dataset).and_return(instance_double(AccessTag.dataset.class, destroy: nil))
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
      project = described_class.create_with_id(name: "test")
      project.associate_with_project(project)
      Account.create_with_id(email: "user1@example.com").tap { _1.associate_with_project(project) }
      Account.create_with_id(email: "user2@example.com").tap { _1.associate_with_project(project) }.update(suspended_at: Time.now)
      expect(project.active?).to be false
    end

    it "returns true if any condition not match" do
      project = described_class.create_with_id(name: "test")
      project.associate_with_project(project)
      Account.create_with_id(email: "user1@example.com").tap { _1.associate_with_project(project) }
      expect(project.active?).to be true
    end
  end

  describe ".default_location" do
    it "returns the location with the highest available core capacity" do
      VmHost.create(allocation_state: "accepting", location: "hetzner-fsn1", total_cores: 10, used_cores: 3) { _1.id = Sshable.create_with_id.id }
      VmHost.create(allocation_state: "accepting", location: "hetzner-fsn1", total_cores: 10, used_cores: 3) { _1.id = Sshable.create_with_id.id }
      VmHost.create(allocation_state: "accepting", location: "hetzner-fsn1", total_cores: 10, used_cores: 1) { _1.id = Sshable.create_with_id.id }
      VmHost.create(allocation_state: "accepting", location: "leaseweb-wdc02", total_cores: 100, used_cores: 99) { _1.id = Sshable.create_with_id.id }
      VmHost.create(allocation_state: "draining", location: "location-4", total_cores: 100, used_cores: 0) { _1.id = Sshable.create_with_id.id }
      VmHost.create(allocation_state: "accepting", location: "github-runners", total_cores: 100, used_cores: 0) { _1.id = Sshable.create_with_id.id }

      expect(project.default_location).to eq("hetzner-fsn1")
    end

    it "provides first location when location with highest available core capacity cannot be determined" do
      expect(project.default_location).to eq Option.locations.first.name
    end
  end

  it "calculates current resource usage" do
    expect(project).to receive(:vms).and_return([instance_double(Vm, vcpus: 2), instance_double(Vm, vcpus: 4)])
    expect(project.current_resource_usage("VmVCpu")).to eq 6

    expect(project).to receive(:github_installations).and_return([instance_double(GithubInstallation, total_active_runner_vcpus: 10), instance_double(GithubInstallation, total_active_runner_vcpus: 20)])
    expect(project.current_resource_usage("GithubRunnerVCpu")).to eq 30

    expect(project).to receive(:postgres_resources).and_return([instance_double(PostgresResource, servers: [instance_double(PostgresServer, vm: instance_double(Vm, vcpus: 2)), instance_double(PostgresServer, vm: instance_double(Vm, vcpus: 4))])])
    expect(project.current_resource_usage("PostgresVCpu")).to eq 6

    expect { project.current_resource_usage("UnknownResource") }.to raise_error(RuntimeError)
  end

  it "calculates effective quota value" do
    project = described_class.create_with_id(name: "test")
    project.add_quota(ProjectQuota.new(value: 1000).tap { _1.quota_id = "14fa6820-bf63-41d2-b35e-4a4dcefd1b15" })
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
