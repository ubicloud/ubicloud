# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::GithubRunner do
  subject(:gr_test) { described_class.new(described_class.assemble([{"name" => "github_runner_ubuntu_2204", "images" => ["github-ubuntu-2204"], "details" => {"repo_name" => "ubicloud/github-e2e-test-workflows", "workflow_name" => "test_2204.yml", "branch_name" => "main"}}])) }

  let(:client) { instance_double(Octokit::Client) }

  before do
    expect(Config).to receive(:github_runner_service_project_id).and_return("fabd95f8-d002-8ed2-9f4c-00625eb7f574")
    expect(Config).to receive(:vm_pool_project_id).and_return("c3fd495f-9888-82d2-8100-7fae94e87e27")
    expect(Config).to receive(:e2e_github_installation_id).and_return(123456).at_least(:once)
    allow(Github).to receive(:installation_client).with(Config.e2e_github_installation_id).and_return(client)
  end

  describe "#start" do
    it "hops to hop_create_vm_pool" do
      expect { gr_test.start }.to hop("create_vm_pool")
    end
  end

  describe "#create_vm_pool" do
    it "creates pool and hops to wait_vm_pool_to_be_ready" do
      label_data = Github.runner_labels["ubicloud"]
      expect(Prog::Vm::VmPool).to receive(:assemble)
        .with(hash_including(size: 1, vm_size: label_data["vm_size"]))
        .and_return(instance_double(Strand, subject: instance_double(VmPool, id: 12345)))
      expect { gr_test.create_vm_pool }.to hop("wait_vm_pool_to_be_ready")
    end
  end

  describe "#wait_vm_pool_to_be_ready" do
    it "hops to trigger_test_runs when the pool is ready" do
      pool = instance_double(VmPool, size: 1)
      expect(VmPool).to receive(:[]).and_return(pool)
      expect(pool).to receive(:vms_dataset).and_return(instance_double(Sequel::Dataset, exclude: [instance_double(Vm)]))
      expect(pool).to receive(:update).with(size: 0)
      expect { gr_test.wait_vm_pool_to_be_ready }.to hop("trigger_test_runs")
    end

    it "naps if the vm in the pool not provisioned yet" do
      pool = instance_double(VmPool, size: 1)
      expect(VmPool).to receive(:[]).and_return(pool)
      expect(pool).to receive(:vms_dataset).and_return(instance_double(Sequel::Dataset, exclude: []))
      expect { gr_test.wait_vm_pool_to_be_ready }.to nap(10)
    end
  end

  describe "#trigger_test_runs" do
    it "triggers test runs" do
      allow(ENV).to receive(:[]).and_call_original
      expect(ENV).to receive(:[]).with("GITHUB_RUN_ID").and_return("12345")
      expect(client).to receive(:workflow_dispatch).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", "main", {inputs: {triggered_by: "12345"}}).and_return(true)
      expect(gr_test).to receive(:sleep).with(30)
      expect { gr_test.trigger_test_runs }.to hop("check_test_runs")
    end

    it "can not triggers test runs" do
      allow(ENV).to receive(:[]).and_call_original
      expect(ENV).to receive(:[]).with("GITHUB_RUN_ID").and_return("12345")
      expect(client).to receive(:workflow_dispatch).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", "main", {inputs: {triggered_by: "12345"}}).and_return(false)
      expect { gr_test.trigger_test_runs }.to hop("clean_resources")
    end
  end

  describe "#check_test_runs" do
    it "check test runs completed" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "success", created_at: Time.now + 10}]})
      expect { gr_test.check_test_runs }.to hop("enable_alien_runners")
    end

    it "check test runs completed for alien runners" do
      expect(gr_test).to receive(:frame).and_return(gr_test.frame.merge({"github_runner_aws_location_id" => "c4cf8b4c-70ec-8820-b311-13284f205306"})).at_least(:once)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "success", created_at: Time.now + 10}]})
      expect { gr_test.check_test_runs }.to hop("clean_resources")
    end

    it "check test runs in progress with nil" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: nil, created_at: Time.now + 10}]})
      expect { gr_test.check_test_runs }.to nap(15)
    end

    it "check test runs in progress state" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "in_progress", created_at: Time.now + 10}]})
      expect { gr_test.check_test_runs }.to nap(15)
    end

    it "check test runs failed" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "failure", created_at: Time.now + 10}]})
      expect { gr_test.check_test_runs }.to hop("enable_alien_runners")
    end

    it "check test runs created before" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "failure", created_at: Time.now - 2 * 60 * 60}]})
      expect { gr_test.check_test_runs }.to hop("enable_alien_runners")
    end
  end

  describe "#enable_alien_runners" do
    it "enables alien runners and hops to trigger_test_runs" do
      location_id = "5f0db214-de30-8420-8a11-98014b01c5b5"
      expect(Config).to receive(:github_runner_aws_location_id).and_return(location_id)
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      expect { gr_test.enable_alien_runners }.to hop("trigger_test_runs")
      expect(Location[location_id]).not_to be_nil
      expect(LocationCredential[location_id].access_key).to eq("access_key")
      expect(gr_test.strand.stack.last).to include({"github_runner_aws_location_id" => location_id})
    end
  end

  describe "#clean_resources" do
    it "waits runners to finish their jobs" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      GithubRunner.create(repository_name: "test-repo", label: "ubicloud")
      expect { gr_test.clean_resources }.to nap(15)
    end

    it "waits vm pools to be destroyed" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      pool = Prog::Vm::VmPool.assemble(size: 1, vm_size: "standard-2", location_id: Location::HETZNER_FSN1_ID, boot_image: "github-ubuntu-2204", storage_size_gib: 86, storage_encrypted: true,
        storage_skip_sync: false, arch: "x64").subject
      expect(VmPool).to receive(:[]).and_return(pool)
      expect { gr_test.clean_resources }.to nap(15)
    end

    it "waits repositories to be destroyed" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      installation = GithubInstallation.create(installation_id: 123, name: "test-user", type: "User")
      repo = Prog::Github::GithubRepositoryNexus.assemble(installation, "ubicloud/ubicloud", "master").subject
      expect { gr_test.clean_resources }.to nap(15)
      expect(repo.destroy_set?).to be(true)
    end

    it "cleans resources and hop finish" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      expect(GithubRunner).to receive(:any?).and_return(false)
      expect(VmPool).to receive(:[]).with(anything).and_return(instance_double(VmPool, vms: [], incr_destroy: nil))
      expect(Location).to receive(:[]).with(anything).and_return(instance_double(Location, destroy: nil))
      expect(Project).to receive(:[]).with(anything).and_return(instance_double(Project, destroy: nil)).at_least(:once)
      expect { gr_test.clean_resources }.to hop("finish")
    end

    it "cleans resources and hop failed" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      expect(GithubRunner).to receive(:any?).and_return(false)
      expect(VmPool).to receive(:[]).with(anything).and_return(instance_double(VmPool, vms: [instance_double(Vm)], incr_destroy: nil))
      expect(Project).to receive(:[]).with(anything).and_return(nil).at_least(:once)
      expect(gr_test).to receive(:frame).and_return({"fail_message" => "Failed test", "test_cases" => gr_test.frame["test_cases"]}).at_least(:once)
      expect { gr_test.clean_resources }.to hop("failed")
    end

    it "cleans resources already cancelled" do
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).and_raise(StandardError)
      expect(GithubRunner).to receive(:any?).and_return(true)
      expect { gr_test.clean_resources }.to nap(15)
    end
  end

  describe "finish" do
    it "finish" do
      expect { gr_test.finish }.to exit({"msg" => "GithubRunner tests are finished!"})
    end
  end

  describe "failed" do
    it "finish" do
      expect { gr_test.failed }.to nap(15)
    end
  end
end
