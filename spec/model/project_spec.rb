# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Project do
  subject(:project) { described_class.new }

  describe ".has_valid_payment_method?" do
    it "returns true when Stripe not enabled" do
      expect(Config).to receive(:stripe_secret_key).and_return(nil)
      expect(project.has_valid_payment_method?).to be true
    end

    it "returns false when no billing info" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      expect(project).to receive(:billing_info).and_return(nil)
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns false when no payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = instance_double(BillingInfo, payment_methods: [])
      expect(project).to receive(:billing_info).and_return(bi)
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns true when has valid payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      pm = instance_double(PaymentMethod)
      bi = instance_double(BillingInfo, payment_methods: [pm])
      expect(project).to receive(:billing_info).and_return(bi)
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
      expect(project).to receive(:access_tags_dataset).and_return(instance_double(AccessTag, destroy: nil))
      expect(project).to receive(:access_policies_dataset).and_return(instance_double(AccessPolicy, destroy: nil))
      expect(project).to receive(:github_installations).and_return([instance_double(GithubInstallation)])
      expect(Prog::Github::DestroyGithubInstallation).to receive(:assemble)
      expect(project).to receive(:update).with(visible: false)
      project.soft_delete
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
    expect(project).to receive(:vms).and_return([instance_double(Vm, cores: 2), instance_double(Vm, cores: 4)])
    expect(project.current_resource_usage("VmCores")).to eq 6

    expect(project).to receive(:github_installations).and_return([instance_double(GithubInstallation, total_active_runner_cores: 10), instance_double(GithubInstallation, total_active_runner_cores: 20)])
    expect(project.current_resource_usage("GithubRunnerCores")).to eq 30

    expect(project).to receive(:postgres_resources).and_return([instance_double(PostgresResource, servers: [instance_double(PostgresServer, vm: instance_double(Vm, cores: 2)), instance_double(PostgresServer, vm: instance_double(Vm, cores: 4))])])
    expect(project.current_resource_usage("PostgresCores")).to eq 6

    expect { project.current_resource_usage("UnknownResource") }.to raise_error(RuntimeError)
  end

  it "calculates effective quota value" do
    project = described_class.create_with_id(name: "test")
    project.add_quota(ProjectQuota.new(value: 1000).tap { _1.quota_id = "14fa6820-bf63-41d2-b35e-4a4dcefd1b15" })
    expect(project.effective_quota_value("VmCores")).to eq 16
    expect(project.effective_quota_value("GithubRunnerCores")).to eq 1000
    expect(project.effective_quota_value("PostgresCores")).to eq 64

    expect(project).to receive(:reputation).and_return("verified").at_least(:once)
    expect(project.effective_quota_value("VmCores")).to eq 128
    expect(project.effective_quota_value("GithubRunnerCores")).to eq 1000
    expect(project.effective_quota_value("PostgresCores")).to eq 128
  end

  it "checks if quota is available" do
    expect(project).to receive(:current_resource_usage).and_return(10).twice
    expect(project).to receive(:effective_quota_value).and_return(20).twice
    expect(project.quota_available?("VmCores", 5)).to be true
    expect(project.quota_available?("VmCores", 20)).to be false
  end

  describe ".create_api_key" do
    it "creates an api key" do
      project = described_class.create_with_id(name: "test")
      expect(project.api_keys.count).to be(0)
      project.create_api_key
      expect(project.reload.api_keys.count).to be(1)
    end
  end
end
