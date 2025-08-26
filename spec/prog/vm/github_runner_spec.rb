# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"
require "octokit"

RSpec.describe Prog::Vm::GithubRunner do
  subject(:nx) {
    described_class.new(Strand.new).tap {
      it.instance_variable_set(:@github_runner, runner)
    }
  }

  let(:runner) do
    customer_project = Project.create(name: "customer")
    runner_project = Project.create(name: "runner-service")
    installation_id = GithubInstallation.create(installation_id: 123, project_id: customer_project.id, name: "ubicloud", type: "Organization", created_at: now - 8 * 24 * 60 * 60).id
    vm_id = create_vm(location_id: Location::GITHUB_RUNNERS_ID, project_id: runner_project.id, boot_image: "github-ubuntu-2204").id
    Sshable.create_with_id(vm_id)
    GithubRunner.create(installation_id:, vm_id:, repository_name: "test-repo", label: "ubicloud-standard-4", created_at: now, allocated_at: now + 10, ready_at: now + 20, workflow_job: {"id" => 123})
  end
  let(:vm) { runner.vm }
  let(:installation) { runner.installation }
  let(:project) { installation.project }
  let(:client) { instance_double(Octokit::Client) }
  let(:now) { Time.utc(2025, 8, 1, 19, 0) }

  before do
    allow(Config).to receive(:github_runner_service_project_id).and_return(vm.project_id)
    allow(Github).to receive(:installation_client).and_return(client)
    allow(Time).to receive(:now).and_return(now)
  end

  describe ".assemble" do
    it "creates github runner and vm with sshable" do
      runner = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud").subject

      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.label).to eq("ubicloud")
    end

    it "creates github runner with custom size" do
      runner = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud-standard-8").subject

      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.label).to eq("ubicloud-standard-8")
    end

    it "fails if label is not valid" do
      expect {
        described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud-standard-1")
      }.to raise_error RuntimeError, "Invalid GitHub runner label: ubicloud-standard-1"
    end
  end

  describe ".pick_vm" do
    it "provisions a VM if the pool is not existing" do
      vm = nx.pick_vm
      expect(vm.pool_id).to be_nil
      expect(vm.sshable.unix_user).to eq("runneradmin")
      expect(vm.unix_user).to eq("runneradmin")
      expect(vm.family).to eq("standard")
      expect(vm.vcpus).to eq(4)
      expect(vm.project_id).to eq(Config.github_runner_service_project_id)
    end

    it "provisions a new vm if pool is valid but there is no vm" do
      VmPool.create(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location_id: Location::GITHUB_RUNNERS_ID, storage_size_gib: 150, arch: "x64")
      vm = nx.pick_vm
      expect(vm.pool_id).to be_nil
      expect(vm.sshable.unix_user).to eq("runneradmin")
      expect(vm.family).to eq("standard")
      expect(vm.vcpus).to eq(4)
    end

    it "uses the existing vm if pool can pick one" do
      pool = VmPool.create(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location_id: Location::GITHUB_RUNNERS_ID, storage_size_gib: 150, arch: "x64", storage_skip_sync: true)
      vm = create_vm(pool_id: pool.id, display_state: "running")
      picked_vm = nx.pick_vm
      expect(vm.id).to eq(picked_vm.id)
    end

    it "uses the premium vm pool if the installation prefers premium runners" do
      pool = VmPool.create(size: 2, vm_size: "premium-4", boot_image: "github-ubuntu-2204", location_id: Location::GITHUB_RUNNERS_ID, storage_size_gib: 150, arch: "x64", storage_skip_sync: true)
      vm = create_vm(pool_id: pool.id, display_state: "running", family: "premium")
      expect(installation).to receive(:premium_runner_enabled?).and_return(true)
      picked_vm = nx.pick_vm
      expect(vm.id).to eq(picked_vm.id)
      expect(picked_vm.family).to eq("premium")
    end

    it "uses the premium vm pool if a free premium upgrade is enabled" do
      pool = VmPool.create(size: 2, vm_size: "premium-4", boot_image: "github-ubuntu-2204", location_id: Location::GITHUB_RUNNERS_ID, storage_size_gib: 150, arch: "x64", storage_skip_sync: true)
      vm = create_vm(pool_id: pool.id, display_state: "running", family: "premium")
      expect(installation).to receive(:premium_runner_enabled?).and_return(false)
      expect(installation).to receive(:free_runner_upgrade?).and_return(true)
      picked_vm = nx.pick_vm
      expect(vm.id).to eq(picked_vm.id)
      expect(picked_vm.family).to eq("premium")
    end

    it "uses alien vms if enabled" do
      project.set_ff_aws_alien_runners_ratio(0.5)
      expect(nx).to receive(:rand).and_return(0.4)
      location = Location.create(name: "eu-central-1", provider: "aws", project_id: vm.project_id, display_name: "aws-eu-central-1", ui_name: "AWS Frankfurt", visible: true)
      expect(Config).to receive(:github_runner_aws_location_id).and_return(location.id)
      picked_vm = nx.pick_vm
      expect(picked_vm.family).to eq("m7a")
      expect(picked_vm.location.aws?).to be(true)
      expect(picked_vm.boot_image).to eq(Config.github_ubuntu_2204_aws_ami_version)
    end
  end

  describe ".update_billing_record" do
    it "not updates billing record if the runner is destroyed before it's ready" do
      runner.update(ready_at: nil)
      expect(nx.update_billing_record).to be_nil
      expect(BillingRecord.count).to eq(0)
    end

    it "not updates billing record if the runner does not pick a job" do
      runner.update(ready_at: now, workflow_job: nil)
      expect(nx.update_billing_record).to be_nil
      expect(BillingRecord.count).to eq(0)
    end

    it "creates new billing record when no daily record" do
      runner.update(ready_at: now - 5 * 60)
      expect(BillingRecord).to receive(:create).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(now, now)).to eq(1)
    end

    it "uses separate billing rate for arm64 runners" do
      runner.update(label: "ubicloud-arm", ready_at: now - 5 * 60)
      expect(BillingRecord).to receive(:create).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(now, now)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("standard-2-arm")
      expect(runner.billed_vm_size).to eq("standard-2-arm")
    end

    it "uses separate billing rate for gpu runners" do
      vm.update(family: "standard-gpu", vcpus: 6)
      runner.update(label: "ubicloud-gpu", ready_at: now - 5 * 60)

      expect(BillingRecord).to receive(:create).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(now, now)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("standard-gpu-6")
      expect(runner.billed_vm_size).to eq("standard-gpu-6")
    end

    it "uses the premium billing rate for upgraded runners" do
      vm.update(family: "premium")
      runner.update(label: "ubicloud-standard-2", ready_at: now - 5 * 60)

      expect(BillingRecord).to receive(:create).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(now, now)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("premium-2")
      expect(runner.billed_vm_size).to eq("premium-2")
    end

    it "uses the original billing rate for runners who were upgraded for free based on runner creation time" do
      vm.update(family: "premium")
      runner.update(label: "ubicloud-standard-2", ready_at: now - 5 * 60, created_at: now - 100)

      expect(installation).to receive(:free_runner_upgrade_expires_at).and_return(now - 50)
      expect(BillingRecord).to receive(:create).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(now, now)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("standard-2")
      expect(runner.billed_vm_size).to eq("standard-2")
    end

    it "uses standard billing rate for alien runners" do
      runner.update(label: "ubicloud-standard-2", ready_at: now - 5 * 60)
      location = Location.create(name: "eu-central-1", provider: "aws", project_id: vm.project_id, display_name: "aws-eu-central-1", ui_name: "AWS Frankfurt", visible: true)
      vm.update(location_id: location.id, family: "m7a")
      expect(vm.location.aws?).to be(true)
      expect(BillingRecord).to receive(:create).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(now, now)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("standard-2")
      expect(runner.billed_vm_size).to eq("standard-2")
    end

    it "updates the amount of existing billing record" do
      runner.update(ready_at: now - 5 * 60)

      expect(BillingRecord).to receive(:create).and_call_original
      # Create a record
      nx.update_billing_record

      expect { nx.update_billing_record }
        .to change { BillingRecord[resource_id: project.id].amount }.from(5).to(10)
    end

    it "create a new record for a new day" do
      today = Time.now
      tomorrow = today + 24 * 60 * 60
      expect(Time).to receive(:now).and_return(today)
      expect(runner).to receive(:ready_at).and_return(today - 5 * 60).twice
      expect(BillingRecord).to receive(:create).and_call_original
      # Create today record
      nx.update_billing_record

      expect(Time).to receive(:now).and_return(tomorrow).at_least(:once)
      expect(runner).to receive(:ready_at).and_return(tomorrow - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create).and_call_original
      # Create tomorrow record
      expect { nx.update_billing_record }
        .to change { BillingRecord.where(resource_id: project.id).count }.from(1).to(2)

      expect(BillingRecord.where(resource_id: project.id).map(&:amount)).to eq([5, 5])
    end

    it "tries 3 times and creates single billing record" do
      runner.update(ready_at: now - 5 * 60)
      expect(BillingRecord).to receive(:create).and_raise(Sequel::Postgres::ExclusionConstraintViolation).exactly(3)
      expect(BillingRecord).to receive(:create).and_call_original

      expect {
        3.times { nx.update_billing_record }
      }.to change { BillingRecord.where(resource_id: project.id).count }.from(0).to(1)
    end

    it "tries 4 times and fails" do
      runner.update(ready_at: now - 5 * 60)
      expect(BillingRecord).to receive(:create).and_raise(Sequel::Postgres::ExclusionConstraintViolation).at_least(:once)

      expect {
        4.times { nx.update_billing_record }
      }.to raise_error(Sequel::Postgres::ExclusionConstraintViolation)
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:update_billing_record)
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_vm_destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("wait_vm_destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "hops to wait_concurrency_limit if there is no capacity" do
      expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
      expect(project).to receive(:active?).and_return(true)

      expect { nx.start }.to hop("wait_concurrency_limit")
    end

    it "hops to allocate_vm if there is capacity" do
      expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(true)
      expect(project).to receive(:active?).and_return(true)

      expect { nx.start }.to hop("allocate_vm")
    end

    it "pops if the project is not active" do
      expect(project).to receive(:active?).and_return(false)

      expect { nx.start }.to exit({"msg" => "Could not provision a runner for inactive project"})
    end
  end

  describe "#wait_concurrency_limit" do
    before do
      [
        [Location::HETZNER_FSN1_ID, "x64", "standard"],
        [Location::GITHUB_RUNNERS_ID, "x64", "standard"],
        [Location::GITHUB_RUNNERS_ID, "x64", "premium"],
        [Location::GITHUB_RUNNERS_ID, "arm64", "standard"]
      ].each do |location_id, arch, family|
        create_vm_host(location_id:, arch:, family:, total_cores: 16, used_cores: 16)
      end
    end

    it "hops to allocate_vm when customer concurrency limit frees up" do
      expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(true)
      expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
    end

    context "when standard runner" do
      it "waits if standard utilization is high" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        expect { nx.wait_concurrency_limit }.to nap
      end

      it "allocates if standard utilization is low" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost[arch: "x64", family: "standard"].update(used_cores: 8)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end
    end

    context "when transparent premium runner" do
      before { installation.update(allocator_preferences: {"family_filter" => ["premium", "standard"]}) }

      it "waits if premium and standard utilizations are high" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        expect { nx.wait_concurrency_limit }.to nap
      end

      it "allocates if standard utilization is high but premium utilization is low" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost[arch: "x64", family: "premium"].update(used_cores: 8)
        expect(runner).not_to receive(:incr_not_upgrade_premium)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end

      it "allocates without upgrade if premium utilization is high but standard utilization is low" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost[arch: "x64", family: "standard"].update(used_cores: 8)
        expect(runner).to receive(:incr_not_upgrade_premium)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end

      it "allocates arm64 runners without checking premium utilization" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        runner.update(label: "ubicloud-standard-4-arm")
        VmHost[arch: "arm64"].update(used_cores: 8)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end
    end

    context "when explicit premium runner" do
      before { runner.update(label: "ubicloud-premium-4") }

      it "waits if premium and standard utilizations are high" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        expect { nx.wait_concurrency_limit }.to nap
      end

      it "allocates if premium utilization is low" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost[arch: "x64", family: "premium"].update(used_cores: 8)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end

      it "waits if premium utilization is high but standard utilization is low" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost[arch: "x64", family: "standard"].update(used_cores: 8)
        expect { nx.wait_concurrency_limit }.to nap
      end
    end

    context "when free premium runner" do
      before { project.set_ff_free_runner_upgrade_until(Time.now + 100).reload }

      it "waits if premium and standard utilizations are high" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        expect { nx.wait_concurrency_limit }.to nap
      end

      it "allocates if premium utilization is low than 50" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost.where(arch: "x64").update(used_cores: 4)
        expect(runner).not_to receive(:incr_not_upgrade_premium)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end

      it "allocates without upgrade if premium utilization is higher than 50" do
        expect(project).to receive(:quota_available?).with("GithubRunnerVCpu", 0).and_return(false)
        VmHost.where(arch: "x64").update(used_cores: 10)
        expect(runner).to receive(:incr_not_upgrade_premium)
        expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
      end
    end
  end

  describe "#allocate_vm" do
    it "picks vm and hops" do
      picked_vm = create_vm(name: "picked-vm")
      expect(nx).to receive(:pick_vm).and_return(picked_vm)
      expect(Clog).to receive(:emit).with("runner_allocated").and_call_original
      expect { nx.allocate_vm }.to hop("wait_vm")
      expect(runner.vm_id).to eq(picked_vm.id)
      expect(runner.allocated_at).to eq(now)
      expect(picked_vm.name).to eq(runner.ubid)
    end
  end

  describe "#wait_vm" do
    it "naps 10 seconds if vm is not allocated yet" do
      vm.update(allocated_at: nil)
      expect { nx.wait_vm }.to nap(10)
    end

    it "naps a second if vm is allocated but not provisioned yet" do
      vm.update(allocated_at: now)
      expect { nx.wait_vm }.to nap(1)
    end

    it "hops if vm is ready" do
      vm.update(allocated_at: now, provisioned_at: now)
      expect { nx.wait_vm }.to hop("setup_environment")
    end
  end

  describe ".setup_info" do
    it "returns setup info with vm pool ubid" do
      vm_host = create_vm_host(total_cores: 4, used_cores: 4, data_center: "FSN1-DC8")
      pool = VmPool.create(size: 1, vm_size: "standard-2", location_id: Location::GITHUB_RUNNERS_ID, boot_image: "github-ubuntu-2204", storage_size_gib: 86)
      vm.update(pool_id: pool.id, vm_host_id: vm_host.id)

      expect(nx.setup_info[:detail]).to eq("Name: #{runner.ubid}\nLabel: ubicloud-standard-4\nVM Family: standard\nArch: x64\nImage: github-ubuntu-2204\nVM Host: #{vm_host.ubid}\nVM Pool: #{pool.ubid}\nLocation: hetzner-fsn1\nDatacenter: FSN1-DC8\nProject: #{project.ubid}\nConsole URL: http://localhost:9292/project/#{project.ubid}/github")
    end

    it "returns setup info without vm host" do
      vm.update(vm_host_id: nil)

      expect(nx.setup_info[:detail]).to eq("Name: #{runner.ubid}\nLabel: ubicloud-standard-4\nVM Family: standard\nArch: x64\nImage: github-ubuntu-2204\nVM Host: \nVM Pool: \nLocation: \nDatacenter: \nProject: #{project.ubid}\nConsole URL: http://localhost:9292/project/#{project.ubid}/github")
    end
  end

  describe "#setup_environment" do
    before do
      vm.update(vm_host_id: create_vm_host(data_center: "FSN1-DC8").id)
    end

    it "hops to register_runner" do
      expect(vm).to receive(:runtime_token).and_return("my_token")
      installation.update(use_docker_mirror: false, cache_enabled: false)
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        echo "image version: $ImageVersion"
        sudo usermod -a -G sudo,adm runneradmin
        jq '. += [{"group":"Ubicloud Managed Runner","detail":"Name: #{runner.ubid}\\nLabel: ubicloud-standard-4\\nVM Family: standard\\nArch: x64\\nImage: github-ubuntu-2204\\nVM Host: #{vm.vm_host.ubid}\\nVM Pool: \\nLocation: hetzner-fsn1\\nDatacenter: FSN1-DC8\\nProject: #{project.ubid}\\nConsole URL: http://localhost:9292/project/#{project.ubid}/github"}]' /imagegeneration/imagedata.json | sudo -u runner tee /home/runner/actions-runner/.setup_info > /dev/null
        echo "UBICLOUD_RUNTIME_TOKEN=my_token
        UBICLOUD_CACHE_URL=http://localhost:9292/runtime/github/" | sudo tee -a /etc/environment > /dev/null
      COMMAND

      expect { nx.setup_environment }.to hop("register_runner")
    end

    it "hops to register_runner with after enabling transparent cache" do
      expect(vm).to receive(:runtime_token).and_return("my_token")
      installation.update(use_docker_mirror: false, cache_enabled: true)
      expect(vm).to receive(:nics).and_return([instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.1/32"))]).at_least(:once)
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        echo "image version: $ImageVersion"
        sudo usermod -a -G sudo,adm runneradmin
        jq '. += [{"group":"Ubicloud Managed Runner","detail":"Name: #{runner.ubid}\\nLabel: ubicloud-standard-4\\nVM Family: standard\\nArch: x64\\nImage: github-ubuntu-2204\\nVM Host: #{vm.vm_host.ubid}\\nVM Pool: \\nLocation: hetzner-fsn1\\nDatacenter: FSN1-DC8\\nProject: #{project.ubid}\\nConsole URL: http://localhost:9292/project/#{project.ubid}/github"}]' /imagegeneration/imagedata.json | sudo -u runner tee /home/runner/actions-runner/.setup_info > /dev/null
        echo "UBICLOUD_RUNTIME_TOKEN=my_token
        UBICLOUD_CACHE_URL=http://localhost:9292/runtime/github/" | sudo tee -a /etc/environment > /dev/null
        echo "CUSTOM_ACTIONS_CACHE_URL=http://10.0.0.1:51123/random_token/" | sudo tee -a /etc/environment > /dev/null
      COMMAND

      expect { nx.setup_environment }.to hop("register_runner")
    end
  end

  describe "#register_runner" do
    it "registers runner hops" do
      expect(client).to receive(:post).with(/.*generate-jitconfig/, hash_including(name: runner.ubid.to_s, labels: [runner.label])).and_return({runner: {id: 123}, encoded_jit_config: "AABBCC$"})
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, stdin: "AABBCC$")
        sudo -u runner tee /home/runner/actions-runner/.jit_token > /dev/null
        sudo systemctl start runner-script.service
      COMMAND
      expect { nx.register_runner }.to hop("wait")
      expect(runner.runner_id).to eq(123)
      expect(runner.ready_at).to eq(now)
    end

    it "deletes the runner if the generate request fails due to 'already exists with the same name' error and the runner script does not start yet." do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: runner.ubid.to_s, labels: [runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate)
        .and_yield({runners: [{name: runner.ubid.to_s, id: 123}]}, instance_double(Sawyer::Response, data: {runners: []}))
        .and_return({runners: [{name: runner.ubid.to_s, id: 123}]})
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("dead")
      expect(client).to receive(:delete).with("/repos/#{runner.repository_name}/actions/runners/123")
      expect(Clog).to receive(:emit).with("Deregistering runner because it already exists").and_call_original
      expect { nx.register_runner }.to nap(5)
    end

    it "hops to wait if the generate request fails due to 'already exists with the same name' error and the runner script is running" do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: runner.ubid.to_s, labels: [runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate)
        .and_yield({runners: [{name: runner.ubid.to_s, id: 123}]}, instance_double(Sawyer::Response, data: {runners: []}))
        .and_return({runners: [{name: runner.ubid.to_s, id: 123}]})
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect { nx.register_runner }.to hop("wait")
      expect(runner.runner_id).to eq(123)
      expect(runner.ready_at).to eq(now)
    end

    it "fails if the generate request fails due to 'already exists with the same name' error but couldn't find the runner" do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: runner.ubid.to_s, labels: [runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate).and_return({runners: []})
      expect(client).not_to receive(:delete)
      expect { nx.register_runner }.to raise_error RuntimeError, "BUG: Failed with runner already exists error but couldn't find it"
    end

    it "fails if the generate request fails due to 'Octokit::Conflict' but it's not already exists error" do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: runner.ubid.to_s, labels: [runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Another issue"}))
      expect { nx.register_runner }.to raise_error Octokit::Conflict
    end

    it "fails without a log if the ssh error doesn't match" do
      expect(client).to receive(:post).with(/.*generate-jitconfig/, hash_including(name: runner.ubid.to_s, labels: [runner.label])).and_return({runner: {id: 123}, encoded_jit_config: "AABBCC$"})
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, stdin: "AABBCC$").and_raise Sshable::SshError.new("command", "", "unknown command", 123, nil)
        sudo -u runner tee /home/runner/actions-runner/.jit_token > /dev/null
        sudo systemctl start runner-script.service
      COMMAND
      expect(Clog).not_to receive(:emit).with("Failed to start runner script").and_call_original
      expect { nx.register_runner }.to raise_error Sshable::SshError
    end
  end

  describe "#wait" do
    it "does not destroy runner if it does not pick a job in five minutes, and busy" do
      runner.update(ready_at: now - 6 * 60, workflow_job: nil)
      expect(client).to receive(:get).and_return({busy: true})
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(nx).not_to receive(:register_deadline).with(nil, 7200)
      expect(runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(60)
    end

    it "destroys runner if it does not pick a job in five minutes and not busy" do
      runner.update(ready_at: now - 6 * 60, workflow_job: nil)
      expect(client).to receive(:get).and_return({busy: false})
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(runner).to receive(:incr_destroy)
      expect(nx).to receive(:register_deadline).twice
      expect(Clog).to receive(:emit).with("The runner did not pick a job").and_call_original

      expect { nx.wait }.to nap(0)
    end

    it "destroys runner if it does not pick a job in five minutes and already deleted" do
      runner.update(ready_at: now - 6 * 60, workflow_job: nil)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(runner).to receive(:incr_destroy)
      expect(nx).to receive(:register_deadline).twice
      expect(Clog).to receive(:emit).with("The runner did not pick a job").and_call_original

      expect { nx.wait }.to nap(0)
    end

    it "does not destroy runner if it doesn not pick a job but two minutes not pass yet" do
      runner.update(ready_at: now - 60, workflow_job: nil)
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(60)
    end

    it "destroys the runner if the runner-script is succeeded" do
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("exited")
      expect(runner).to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "provisions a spare runner and destroys the current one if the runner-script is failed" do
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("failed")
      expect(runner).to receive(:provision_spare_runner)
      expect(runner).to receive(:incr_destroy)
      expect { nx.wait }.to nap(0)
    end

    it "naps if the runner-script is running" do
      expect(vm.sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")

      expect { nx.wait }.to nap(60)
    end
  end

  describe ".collect_final_telemetry" do
    before do
      vm.update(vm_host_id: create_vm_host(data_center: "FSN1-DC8").id)
    end

    it "Logs journalctl, docker limits, and cache proxy log if workflow_job is not successful" do
      runner.update(workflow_job: {"conclusion" => "failure"})
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ln /vm/#{vm.inhost_name}/serial.log /var/log/ubicloud/serials/#{runner.ubid}_serial.log")
      expect(vm.sshable).to receive(:cmd).with("journalctl -u runner-script -t 'run-withenv.sh' -t 'systemd' --no-pager | grep -Fv Started")
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, log: false)
        TOKEN=$(curl -m 10 -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
        curl -m 10 -s --head -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep ratelimit
      COMMAND
      expect(vm.sshable).to receive(:cmd).with("sudo cat /var/log/cacheproxy.log", log: false).and_return("Received request - method: GET urlPath: foo\nReceived request - method: GET urlPath: foo\nGetCacheEntry  request failed with status code: 204\n")
      expect(Clog).to receive(:emit).with("Cache proxy log line counts") do |&blk|
        expect(blk.call).to eq(cache_proxy_log_line_counts: {"Received request - method: GET urlPath: foo" => 2, "GetCacheEntry  request failed with status code: 204" => 1})
      end

      nx.collect_final_telemetry
    end

    it "Logs journalctl, docker limits, and cache proxy log if workflow_job is nil" do
      runner.update(workflow_job: nil)
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo ln /vm/#{vm.inhost_name}/serial.log /var/log/ubicloud/serials/#{runner.ubid}_serial.log")
      expect(vm.sshable).to receive(:cmd).with("journalctl -u runner-script -t 'run-withenv.sh' -t 'systemd' --no-pager | grep -Fv Started")
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, log: false)
        TOKEN=$(curl -m 10 -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
        curl -m 10 -s --head -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep ratelimit
      COMMAND
      expect(vm.sshable).to receive(:cmd).with("sudo cat /var/log/cacheproxy.log", log: false).and_return("Received request - method: GET urlPath: foo\nReceived request - method: GET urlPath: foo\nGetCacheEntry  request failed with status code: 204\n")

      expect(Clog).to receive(:emit).with("Cache proxy log line counts") do |&blk|
        expect(blk.call).to eq(cache_proxy_log_line_counts: {"Received request - method: GET urlPath: foo" => 2, "GetCacheEntry  request failed with status code: 204" => 1})
      end

      nx.collect_final_telemetry
    end

    it "Logs docker limits and cache proxy log if workflow_job is successful" do
      runner.update(workflow_job: {"conclusion" => "success"})
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, log: false).and_return("ratelimit-limit: 100;w=21600\nratelimit-remaining: 98;w=21600\ndocker-ratelimit-source: 192.168.1.1\n")
        TOKEN=$(curl -m 10 -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
        curl -m 10 -s --head -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep ratelimit
      COMMAND
      expect(Clog).to receive(:emit).with("Remaining DockerHub rate limits") do |&blk|
        expect(blk.call).to eq(dockerhub_rate_limits: {limit: 100, limit_window: 21600, remaining: 98, remaining_window: 21600, source: "192.168.1.1"})
      end
      expect(vm.sshable).to receive(:cmd).with("sudo cat /var/log/cacheproxy.log", log: false).and_return("Received request - method: GET urlPath: foo\nReceived request - method: GET urlPath: foo\nGetCacheEntry  request failed with status code: 204\n")

      expect(Clog).to receive(:emit).with("Cache proxy log line counts") do |&blk|
        expect(blk.call).to eq(cache_proxy_log_line_counts: {"Received request - method: GET urlPath: foo" => 2, "GetCacheEntry  request failed with status code: 204" => 1})
      end

      nx.collect_final_telemetry
    end

    it "Logs docker limits and empty cache proxy log if workflow_job is successful" do
      runner.update(workflow_job: {"conclusion" => "success"})
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, log: false).and_return("ratelimit-limit: 100;w=21600\nratelimit-remaining: 98;w=21600\ndocker-ratelimit-source: 192.168.1.1\n")
        TOKEN=$(curl -m 10 -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
        curl -m 10 -s --head -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep ratelimit
      COMMAND
      expect(Clog).to receive(:emit).with("Remaining DockerHub rate limits") do |&blk|
        expect(blk.call).to eq(dockerhub_rate_limits: {limit: 100, limit_window: 21600, remaining: 98, remaining_window: 21600, source: "192.168.1.1"})
      end
      expect(vm.sshable).to receive(:cmd).with("sudo cat /var/log/cacheproxy.log", log: false).and_return("")

      expect(Clog).to receive(:emit).with("Cache proxy log line counts") do |&blk|
        expect(blk.call).to eq(cache_proxy_log_line_counts: {})
      end

      nx.collect_final_telemetry
    end

    it "Logs docker limits and nil cache proxy log if workflow_job is successful" do
      runner.update(workflow_job: {"conclusion" => "success"})
      expect(vm.sshable).to receive(:cmd).with(<<~COMMAND, log: false).and_return("ratelimit-limit: 100;w=21600\nratelimit-remaining: 98;w=21600\ndocker-ratelimit-source: 192.168.1.1\n")
        TOKEN=$(curl -m 10 -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
        curl -m 10 -s --head -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep ratelimit
      COMMAND
      expect(Clog).to receive(:emit).with("Remaining DockerHub rate limits") do |&blk|
        expect(blk.call).to eq(dockerhub_rate_limits: {limit: 100, limit_window: 21600, remaining: 98, remaining_window: 21600, source: "192.168.1.1"})
      end
      expect(vm.sshable).to receive(:cmd).with("sudo cat /var/log/cacheproxy.log", log: false).and_return(nil)

      nx.collect_final_telemetry
    end

    it "doesn't fail if it failed due to Sshable::SshError" do
      runner.update(workflow_job: {"conclusion" => "success"})
      expect(vm.sshable).to receive(:cmd).and_raise Sshable::SshError.new("bogus", "", "", nil, nil)
      expect(Clog).to receive(:emit).with("Failed to collect final telemetry").and_call_original

      nx.collect_final_telemetry
    end

    it "doesn't fail if it failed due to Net::SSH::ConnectionTimeout" do
      runner.update(workflow_job: {"conclusion" => "success"})
      expect(vm.sshable).to receive(:cmd).and_raise Net::SSH::ConnectionTimeout
      expect(Clog).to receive(:emit).with("Failed to collect final telemetry").and_call_original

      nx.collect_final_telemetry
    end
  end

  describe "#destroy" do
    it "naps if runner not deregistered yet" do
      expect(client).to receive(:get).and_return(busy: false)
      expect(client).to receive(:delete)

      expect { nx.destroy }.to nap(5)
    end

    it "naps if runner still running a job" do
      expect(client).to receive(:get).and_return(busy: true)

      expect { nx.destroy }.to nap(15)
    end

    it "destroys resources and hops if runner deregistered" do
      vm.update(vm_host_id: create_vm_host.id)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
      expect(nx).to receive(:collect_final_telemetry)
      fw = instance_double(Firewall)
      ps = instance_double(PrivateSubnet, firewalls: [fw])
      expect(fw).to receive(:destroy)
      expect(ps).to receive(:incr_destroy)
      expect(vm).to receive(:private_subnets).and_return([ps])
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "skip deregistration and destroy vm immediately" do
      vm.update(vm_host_id: create_vm_host.id)
      expect(nx).to receive(:decr_destroy)
      expect(runner).to receive(:skip_deregistration_set?).and_return(true)
      expect(nx).to receive(:collect_final_telemetry)
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "does not collect telemetry if the vm not allocated" do
      vm.update(vm_host_id: nil)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(nx).not_to receive(:collect_final_telemetry)
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "does not destroy vm if it's already destroyed" do
      runner.update(vm_id: nil)
      expect(nx).to receive(:vm).and_return(nil).at_least(:once)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end
  end

  describe "#wait_vm_destroy" do
    it "naps if vm not destroyed yet" do
      expect { nx.wait_vm_destroy }.to nap(10)
    end

    it "extends deadline if vm prevents destroy" do
      expect(runner.vm).to receive(:prevent_destroy_set?).and_return(true)
      expect(nx).to receive(:register_deadline).with(nil, 15 * 60, allow_extension: true)
      expect { nx.wait_vm_destroy }.to nap(10)
    end

    it "pops if vm destroyed" do
      expect(nx).to receive(:vm).and_return(nil).twice
      expect(runner).to receive(:destroy)

      expect { nx.wait_vm_destroy }.to exit({"msg" => "github runner deleted"})
    end
  end
end
