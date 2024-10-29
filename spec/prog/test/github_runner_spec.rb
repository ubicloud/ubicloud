# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::GithubRunner do
  subject(:gr_test) { described_class.new(described_class.assemble(12345, ["github_runner_ubuntu_2204"])) }

  before do
    expect(Config).to receive(:github_runner_service_project_id).and_return("fabd95f8-d002-8ed2-9f4c-00625eb7f574")
    expect(Config).to receive(:vm_pool_project_id).and_return("c3fd495f-9888-82d2-8100-7fae94e87e27")
    expect(Config).to receive(:e2e_github_installation_id).and_return(123456).at_least(:once)
  end

  describe "#start" do
    it "hops to hop_download_boot_images" do
      expect { gr_test.start }.to hop("download_boot_images")
    end
  end

  describe "#download_boot_images" do
    it "hops to hop_wait_download_boot_images" do
      expect(gr_test).to receive(:bud).with(Prog::DownloadBootImage, {"subject_id" => 12345, "image_name" => "github-ubuntu-2204"})
      expect { gr_test.download_boot_images }.to hop("wait_download_boot_images")
    end
  end

  describe "#wait_download_boot_images" do
    it "hops to hop_wait_download_boot_images" do
      expect(gr_test).to receive(:reap)
      expect(gr_test).to receive(:leaf?).and_return(true)
      expect { gr_test.wait_download_boot_images }.to hop("create_vm_pool")
    end

    it "stays in wait_download_boot_images" do
      expect(gr_test).to receive(:reap)
      expect(gr_test).to receive(:leaf?).and_return(false)
      expect(gr_test).to receive(:donate).and_call_original
      expect { gr_test.wait_download_boot_images }.to nap(1)
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
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_dispatch).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", "main").and_return(true)
      expect(gr_test).to receive(:sleep).with(30)
      expect { gr_test.trigger_test_runs }.to hop("check_test_runs")
    end

    it "can not triggers test runs" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_dispatch).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", "main").and_return(false)
      expect { gr_test.trigger_test_runs }.to hop("clean_resources")
    end
  end

  describe "#check_test_runs" do
    it "check test runs completed" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "success", created_at: Time.now}]})
      expect(gr_test).to receive(:frame).and_return({"created_at" => Time.new(2023, 1, 1).to_s, "test_cases" => ["github_runner_ubuntu_2204"]}).at_least(:once)
      expect { gr_test.check_test_runs }.to hop("clean_resources")
    end

    it "check test runs in progress with nil" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: nil, created_at: Time.now}]})
      expect(gr_test).to receive(:frame).and_return({"created_at" => Time.new(2023, 1, 1).to_s, "test_cases" => ["github_runner_ubuntu_2204"]}).at_least(:once)
      expect { gr_test.check_test_runs }.to nap(15)
    end

    it "check test runs in progress state" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "in_progress", created_at: Time.now}]})
      expect(gr_test).to receive(:frame).and_return({"created_at" => Time.new(2023, 1, 1).to_s, "test_cases" => ["github_runner_ubuntu_2204"]}).at_least(:once)
      expect { gr_test.check_test_runs }.to nap(15)
    end

    it "check test runs failed" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "failure", created_at: Time.now}]})
      expect(gr_test).to receive(:frame).and_return({"created_at" => Time.new(2023, 1, 1).to_s, "test_cases" => ["github_runner_ubuntu_2204"]}).at_least(:once)
      expect { gr_test.check_test_runs }.to hop("clean_resources")
    end

    it "check test runs created before" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{conclusion: "failure", created_at: Time.new(2023, 1, 1)}]})
      expect(gr_test).to receive(:frame).and_return({"created_at" => Time.now.to_s, "test_cases" => ["github_runner_ubuntu_2204"]}).at_least(:once)
      expect { gr_test.check_test_runs }.to hop("clean_resources")
    end
  end

  describe "#clean_resources" do
    it "not clean with github exists" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client).at_least(:twice)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      expect(GithubRunner).to receive(:any?).and_return(true)
      expect { gr_test.clean_resources }.to nap(15)
    end

    it "cleans resources and hop finish" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client).at_least(:twice)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      expect(GithubRunner).to receive(:any?).and_return(false)
      expect(VmPool).to receive(:[]).with(anything).and_return(instance_double(VmPool, vms: [], incr_destroy: nil))
      expect(Project).to receive(:[]).with(anything).and_return(instance_double(Project, destroy: nil)).at_least(:once)
      expect { gr_test.clean_resources }.to hop("finish")
    end

    it "cleans resources and hop failed" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client).at_least(:twice)
      expect(client).to receive(:workflow_runs).with("ubicloud/github-e2e-test-workflows", "test_2204.yml", {branch: "main"}).and_return({workflow_runs: [{id: 10}]})
      expect(client).to receive(:cancel_workflow_run).with("ubicloud/github-e2e-test-workflows", 10)
      expect(GithubRunner).to receive(:any?).and_return(false)
      expect(VmPool).to receive(:[]).with(anything).and_return(instance_double(VmPool, vms: [instance_double(Vm)], incr_destroy: nil))
      expect(Project).to receive(:[]).with(anything).and_return(nil).at_least(:once)
      expect(gr_test).to receive(:frame).and_return({"fail_message" => "Failed test", "test_cases" => ["github_runner_ubuntu_2204"]}).at_least(:once)
      expect { gr_test.clean_resources }.to hop("failed")
    end

    it "cleans resources already cancelled" do
      client = instance_double(Octokit::Client)
      expect(gr_test).to receive(:client).and_return(client).at_least(:twice)
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

  describe "get_client" do
    it "get_client" do
      expect(Github).to receive(:installation_client).with(Config.e2e_github_installation_id).and_return(Octokit::Client)

      gr_test.client
    end
  end
end
