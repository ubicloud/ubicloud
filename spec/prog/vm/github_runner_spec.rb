# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"
require "octokit"

RSpec.describe Prog::Vm::GithubRunner do
  subject(:nx) {
    described_class.new(Strand.new).tap {
      _1.instance_variable_set(:@github_runner, github_runner)
    }
  }

  let(:github_runner) {
    GithubRunner.new(installation_id: "", repository_name: "test-repo", label: "ubicloud-standard-4", ready_at: Time.now, created_at: Time.now).tap {
      _1.id = GithubRunner.generate_uuid
    }
  }

  let(:vm) {
    Vm.new(family: "standard", cores: 1, name: "dummy-vm", location: "github-runners").tap {
      _1.id = "788525ed-d6f0-4937-a844-323d4fd91946"
    }
  }
  let(:sshable) { instance_double(Sshable) }
  let(:client) { instance_double(Octokit::Client) }

  before do
    allow(Github).to receive(:installation_client).and_return(client)
    allow(github_runner).to receive_messages(vm: vm, installation: instance_double(GithubInstallation, installation_id: 123))
    allow(vm).to receive_messages(sshable: sshable, vm_host: instance_double(VmHost, ubid: "vhfdmbbtdz3j3h8hccf8s9wz94"))
  end

  describe ".assemble" do
    it "creates github runner and vm with sshable" do
      project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")

      st = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud")

      runner = GithubRunner[st.id]
      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.label).to eq("ubicloud")
    end

    it "creates github runner with custom size" do
      project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")
      st = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud-standard-8")

      runner = GithubRunner[st.id]
      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.label).to eq("ubicloud-standard-8")
    end

    it "fails if label is not valid" do
      expect {
        described_class.assemble(instance_double(GithubInstallation), repository_name: "test-repo", label: "ubicloud-standard-1")
      }.to raise_error RuntimeError, "Invalid GitHub runner label: ubicloud-standard-1"
    end
  end

  describe ".pick_vm" do
    let(:project) { Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) } }

    before do
      runner_project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:github_runner_service_project_id).and_return(runner_project.id)
    end

    it "provisions a VM if the pool is not existing" do
      expect(VmPool).to receive(:where).and_return([])
      expect(Prog::Vm::Nexus).to receive(:assemble).and_call_original
      expect(FirewallRule).to receive(:create_with_id).and_call_original.at_least(:once)
      vm = nx.pick_vm
      expect(vm).not_to be_nil
      expect(vm.sshable.unix_user).to eq("runneradmin")
      expect(vm.family).to eq("standard")
      expect(vm.cores).to eq(2)
      expect(vm.projects.map(&:id)).to include(Config.github_runner_service_project_id)
    end

    it "provisions a new vm if pool is valid but there is no vm" do
      git_runner_pool = VmPool.create_with_id(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners", storage_size_gib: 150, arch: "x64")
      expect(VmPool).to receive(:where).with(
        vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners",
        storage_size_gib: 150, storage_encrypted: true,
        storage_skip_sync: true, arch: "x64"
      ).and_return([git_runner_pool])
      expect(git_runner_pool).to receive(:pick_vm).and_return(nil)
      expect(Prog::Vm::Nexus).to receive(:assemble).and_call_original
      expect(FirewallRule).to receive(:create_with_id).and_call_original.at_least(:once)
      vm = nx.pick_vm
      expect(vm).not_to be_nil
      expect(vm.sshable.unix_user).to eq("runneradmin")
      expect(vm.family).to eq("standard")
      expect(vm.cores).to eq(2)
    end

    it "uses the existing vm if pool can pick one" do
      git_runner_pool = VmPool.create_with_id(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners", storage_size_gib: 150, arch: "arm64")
      expect(VmPool).to receive(:where).with(
        vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners",
        storage_size_gib: 150, storage_encrypted: true,
        storage_skip_sync: true, arch: "arm64"
      ).and_return([git_runner_pool])
      expect(git_runner_pool).to receive(:pick_vm).and_return(vm)
      expect(github_runner).to receive(:label).and_return("ubicloud-standard-4-arm").at_least(:once)
      vm = nx.pick_vm
      expect(vm).not_to be_nil
      expect(vm.name).to eq("dummy-vm")
    end
  end

  describe ".update_billing_record" do
    let(:project) { Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) } }

    before do
      allow(github_runner).to receive(:installation).and_return(instance_double(GithubInstallation, project: project)).at_least(:once)
      allow(github_runner).to receive(:workflow_job).and_return({"id" => 123})
    end

    it "not updates billing record if the runner is destroyed before it's ready" do
      expect(github_runner).to receive(:ready_at).and_return(nil)

      expect(nx.update_billing_record).to be_nil
      expect(BillingRecord.count).to eq(0)
    end

    it "not updates billing record if the runner does not pick a job" do
      expect(github_runner).to receive(:ready_at).and_return(Time.now)
      expect(github_runner).to receive(:workflow_job).and_return(nil)

      expect(nx.update_billing_record).to be_nil
      expect(BillingRecord.count).to eq(0)
    end

    it "creates new billing record when no daily record" do
      skip_if_frozen
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(time, time)).to eq(1)
    end

    it "uses separate billing rate for arm64 runners" do
      skip_if_frozen
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:label).and_return("ubicloud-arm").at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(time, time)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("standard-2-arm")
    end

    it "uses separate billing rate for gpu runners" do
      skip_if_frozen
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:label).and_return("ubicloud-gpu").at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(time, time)).to eq(1)
      expect(br.billing_rate["resource_family"]).to eq("standard-gpu-6")
    end

    it "updates the amount of existing billing record" do
      skip_if_frozen
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      # Create a record
      nx.update_billing_record

      expect { nx.update_billing_record }
        .to change { BillingRecord[resource_id: project.id].amount }.from(5).to(10)
    end

    it "create a new record for a new day" do
      skip_if_frozen
      today = Time.now
      tomorrow = today + 24 * 60 * 60
      expect(Time).to receive(:now).and_return(today).exactly(5)
      expect(github_runner).to receive(:ready_at).and_return(today - 5 * 60).twice
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      # Create today record
      nx.update_billing_record

      expect(Time).to receive(:now).and_return(tomorrow).at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(tomorrow - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      # Create tomorrow record
      expect { nx.update_billing_record }
        .to change { BillingRecord.where(resource_id: project.id).count }.from(1).to(2)

      expect(BillingRecord.where(resource_id: project.id).map(&:amount)).to eq([5, 5])
    end

    it "tries 3 times and creates single billing record" do
      skip_if_frozen
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_raise(Sequel::Postgres::ExclusionConstraintViolation).exactly(3)
      expect(BillingRecord).to receive(:create_with_id).and_call_original

      expect {
        3.times { nx.update_billing_record }
      }.to change { BillingRecord.where(resource_id: project.id).count }.from(0).to(1)
    end

    it "tries 4 times and fails" do
      skip_if_frozen
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_raise(Sequel::Postgres::ExclusionConstraintViolation).at_least(:once)

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
      dataset = instance_double(Sequel::Dataset, for_update: instance_double(Sequel::Dataset, all: []))

      installation = instance_double(GithubInstallation)
      project = instance_double(Project, quota_available?: false, github_installations: [installation])

      expect(github_runner).to receive(:installation).and_return(installation).at_least(:once)
      expect(github_runner.installation).to receive(:project_dataset).and_return(dataset)
      expect(github_runner.installation).to receive(:project).and_return(project).at_least(:once)

      expect { nx.start }.to hop("wait_concurrency_limit")
    end

    it "hops to allocate_vm if there is capacity" do
      dataset = instance_double(Sequel::Dataset, for_update: instance_double(Sequel::Dataset, all: []))

      installation = instance_double(GithubInstallation)
      project = instance_double(Project, quota_available?: true, github_installations: [installation])

      expect(github_runner).to receive(:installation).and_return(installation).at_least(:once)
      expect(github_runner.installation).to receive(:project_dataset).and_return(dataset)
      expect(github_runner.installation).to receive(:project).and_return(project).at_least(:once)

      expect { nx.start }.to hop("allocate_vm")
    end
  end

  describe "#wait_concurrency_limit" do
    before do
      [["hetzner-hel1", "x64"], ["github-runners", "x64"], ["github-runners", "arm64"]].each_with_index do |(location, arch), i|
        ssh = Sshable.create_with_id(host: "0.0.0.#{i}")
        VmHost.create(location: location, allocation_state: "accepting", arch: arch, total_cores: 16, used_cores: 16) { _1.id = ssh.id }
      end
    end

    it "waits until customer concurrency limit frees up" do
      dataset = instance_double(Sequel::Dataset, for_update: instance_double(Sequel::Dataset, all: []))

      installation = instance_double(GithubInstallation)
      project = instance_double(Project, quota_available?: false, github_installations: [installation])
      expect(project).to receive(:effective_quota_value).with("GithubRunnerCores").and_return(1).at_least(:once)

      expect(github_runner).to receive(:installation).and_return(installation).at_least(:once)
      expect(github_runner.installation).to receive(:project_dataset).and_return(dataset)
      expect(github_runner.installation).to receive(:project).and_return(project).at_least(:once)

      expect { nx.wait_concurrency_limit }.to nap
    end

    it "hops to allocate_vm when customer concurrency limit frees up" do
      dataset = instance_double(Sequel::Dataset, for_update: instance_double(Sequel::Dataset, all: []))

      installation = instance_double(GithubInstallation)
      project = instance_double(Project, quota_available?: true, github_installations: [installation])

      expect(github_runner).to receive(:installation).and_return(installation).at_least(:once)
      expect(github_runner.installation).to receive(:project_dataset).and_return(dataset)
      expect(github_runner.installation).to receive(:project).and_return(project).at_least(:once)

      expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
    end

    it "hops to allocate_vm when customer concurrency limit is full but the overall utilization is low" do
      dataset = instance_double(Sequel::Dataset, for_update: instance_double(Sequel::Dataset, all: []))

      installation = instance_double(GithubInstallation)
      project = instance_double(Project, quota_available?: false, github_installations: [installation])
      expect(project).to receive(:effective_quota_value).with("GithubRunnerCores").and_return(1).at_least(:once)

      expect(github_runner).to receive(:installation).and_return(installation).at_least(:once)
      expect(github_runner.installation).to receive(:project_dataset).and_return(dataset)
      expect(github_runner.installation).to receive(:project).and_return(project).at_least(:once)
      VmHost[arch: "x64"].update(used_cores: 4)
      expect { nx.wait_concurrency_limit }.to hop("allocate_vm")
    end

    it "naps for a long time if the quota is set to 0" do
      dataset = instance_double(Sequel::Dataset, for_update: instance_double(Sequel::Dataset, all: []))

      installation = instance_double(GithubInstallation)
      project = instance_double(Project, quota_available?: false, github_installations: [installation])
      expect(project).to receive(:effective_quota_value).with("GithubRunnerCores").and_return(0)
      expect(github_runner.installation).to receive(:project_dataset).and_return(dataset)
      expect(github_runner.installation).to receive(:project).and_return(project).at_least(:once)

      expect { nx.wait_concurrency_limit }.to nap(2592000)
    end
  end

  describe "#allocate_vm" do
    it "picks vm and hops" do
      expect(nx).to receive(:pick_vm).and_return(vm)
      expect(github_runner).to receive(:update).with(vm_id: vm.id)
      expect(vm).to receive(:update).with(name: github_runner.ubid)
      expect(github_runner).to receive(:reload).and_return(github_runner)
      expect(Clog).to receive(:emit).with("runner_allocated").and_call_original
      expect { nx.allocate_vm }.to hop("wait_vm")
    end
  end

  describe "#wait_vm" do
    it "naps 13 seconds if vm is not allocated yet" do
      expect(vm).to receive(:allocated_at).and_return(nil)
      expect { nx.wait_vm }.to nap(13)
    end

    it "naps a second if vm is allocated but not provisioned yet" do
      expect(vm).to receive(:allocated_at).and_return(Time.now)
      expect { nx.wait_vm }.to nap(1)
    end

    it "hops if vm is ready" do
      expect(vm).to receive_messages(allocated_at: Time.now, provisioned_at: Time.now)
      expect { nx.wait_vm }.to hop("setup_environment")
    end
  end

  describe ".setup_info" do
    it "returns setup info with vm pool ubid" do
      expect(vm).to receive(:pool_id).and_return("ccd51c1e-2c78-8f76-b182-467e6cdc51f0").at_least(:once)
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, ubid: "vhfdmbbtdz3j3h8hccf8s9wz94", location: "hetzner-hel1", data_center: "FSN1-DC8")).at_least(:once)
      expect(github_runner.installation).to receive(:project).and_return(instance_double(Project, ubid: "pjwnadpt27b21p81d7334f11rx", path: "/project/pjwnadpt27b21p81d7334f11rx")).at_least(:once)

      expect(nx.setup_info[:detail]).to eq("Name: #{github_runner.ubid}\nLabel: ubicloud-standard-4\nArch: \nImage: \nVM Host: vhfdmbbtdz3j3h8hccf8s9wz94\nVM Pool: vpskahr7hcf26p614czkcvh8z1\nLocation: hetzner-hel1\nDatacenter: FSN1-DC8\nProject: pjwnadpt27b21p81d7334f11rx\nConsole URL: http://localhost:9292/project/pjwnadpt27b21p81d7334f11rx/github")
    end
  end

  describe "#setup_environment" do
    it "hops to register_runner" do
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, ubid: "vhfdmbbtdz3j3h8hccf8s9wz94", location: "hetzner-hel1", data_center: "FSN1-DC8")).at_least(:once)
      expect(vm).to receive(:runtime_token).and_return("my_token")
      expect(github_runner.installation).to receive(:project).and_return(instance_double(Project, ubid: "pjwnadpt27b21p81d7334f11rx", path: "/project/pjwnadpt27b21p81d7334f11rx", get_ff_transparent_cache: false)).at_least(:once)
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        echo "image version: $ImageVersion"
        sudo usermod -a -G sudo,adm runneradmin
        jq '. += [{"group":"Ubicloud Managed Runner","detail":"Name: #{github_runner.ubid}\\nLabel: ubicloud-standard-4\\nArch: \\nImage: \\nVM Host: vhfdmbbtdz3j3h8hccf8s9wz94\\nVM Pool: \\nLocation: hetzner-hel1\\nDatacenter: FSN1-DC8\\nProject: pjwnadpt27b21p81d7334f11rx\\nConsole URL: http://localhost:9292/project/pjwnadpt27b21p81d7334f11rx/github"}]' /imagegeneration/imagedata.json | sudo -u runner tee /home/runner/actions-runner/.setup_info
        echo "UBICLOUD_RUNTIME_TOKEN=my_token
        UBICLOUD_CACHE_URL=http://localhost:9292/runtime/github/" | sudo tee -a /etc/environment
      COMMAND

      expect { nx.setup_environment }.to hop("register_runner")
    end

    it "hops to register_runner with after enabling transparent cache" do
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, ubid: "vhfdmbbtdz3j3h8hccf8s9wz94", location: "hetzner-hel1", data_center: "FSN1-DC8")).at_least(:once)
      expect(vm).to receive(:runtime_token).and_return("my_token")
      expect(github_runner.installation).to receive(:project).and_return(instance_double(Project, ubid: "pjwnadpt27b21p81d7334f11rx", path: "/project/pjwnadpt27b21p81d7334f11rx", get_ff_transparent_cache: true)).at_least(:once)
      expect(vm).to receive(:nics).and_return([instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.1/32"))])
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        echo "image version: $ImageVersion"
        sudo usermod -a -G sudo,adm runneradmin
        jq '. += [{"group":"Ubicloud Managed Runner","detail":"Name: #{github_runner.ubid}\\nLabel: ubicloud-standard-4\\nArch: \\nImage: \\nVM Host: vhfdmbbtdz3j3h8hccf8s9wz94\\nVM Pool: \\nLocation: hetzner-hel1\\nDatacenter: FSN1-DC8\\nProject: pjwnadpt27b21p81d7334f11rx\\nConsole URL: http://localhost:9292/project/pjwnadpt27b21p81d7334f11rx/github"}]' /imagegeneration/imagedata.json | sudo -u runner tee /home/runner/actions-runner/.setup_info
        echo "UBICLOUD_RUNTIME_TOKEN=my_token
        UBICLOUD_CACHE_URL=http://localhost:9292/runtime/github/" | sudo tee -a /etc/environment
        echo "CUSTOM_ACTIONS_CACHE_URL=http://10.0.0.1:51123/random_token/" | sudo tee -a /etc/environment
      COMMAND

      expect { nx.setup_environment }.to hop("register_runner")
    end
  end

  describe "#register_runner" do
    it "registers runner hops" do
      expect(client).to receive(:post).with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label])).and_return({runner: {id: 123}, encoded_jit_config: "AABBCC"})
      expect(sshable).to receive(:cmd).with("sudo -- xargs -I{} -- systemd-run --uid runner --gid runner --working-directory '/home/runner' --unit runner-script --remain-after-exit -- /home/runner/actions-runner/run-withenv.sh {}",
        stdin: "AABBCC")
      expect(github_runner).to receive(:update).with(runner_id: 123, ready_at: anything)

      expect { nx.register_runner }.to hop("wait")
    end

    it "deletes the runner if the generate request fails due to 'already exists with the same name' error and the runner script does not start yet." do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate)
        .and_yield({runners: [{name: github_runner.ubid.to_s, id: 123}]}, instance_double(Sawyer::Response, data: {runners: []}))
        .and_return({runners: [{name: github_runner.ubid.to_s, id: 123}]})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("dead")
      expect(client).to receive(:delete).with("/repos/#{github_runner.repository_name}/actions/runners/123")
      expect(Clog).to receive(:emit).with("Deregistering runner because it already exists").and_call_original
      expect { nx.register_runner }.to nap(5)
    end

    it "hops to wait if the generate request fails due to 'already exists with the same name' error and the runner script is running" do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate)
        .and_yield({runners: [{name: github_runner.ubid.to_s, id: 123}]}, instance_double(Sawyer::Response, data: {runners: []}))
        .and_return({runners: [{name: github_runner.ubid.to_s, id: 123}]})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).to receive(:update).with(runner_id: 123, ready_at: anything)
      expect { nx.register_runner }.to hop("wait")
    end

    it "fails if the generate request fails due to 'already exists with the same name' error but couldn't find the runner" do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate).and_return({runners: []})
      expect(client).not_to receive(:delete)
      expect { nx.register_runner }.to raise_error RuntimeError, "BUG: Failed with runner already exists error but couldn't find it"
    end

    it "fails if the generate request fails due to 'Octokit::Conflict' but it's not already exists error" do
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Another issue"}))
      expect { nx.register_runner }.to raise_error Octokit::Conflict
    end
  end

  describe "#wait" do
    it "does not destroy runner if it does not pick a job in five minutes, and busy" do
      skip_if_frozen
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 6 * 60)
      expect(client).to receive(:get).and_return({busy: true})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys runner if it does not pick a job in five minutes and not busy" do
      skip_if_frozen
      expect(github_runner).to receive(:workflow_job).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 6 * 60)
      expect(client).to receive(:get).and_return({busy: false})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).to receive(:incr_destroy)
      expect(Clog).to receive(:emit).with("The runner does not pick a job").and_call_original

      expect { nx.wait }.to nap(0)
    end

    it "does not destroy runner if it doesn not pick a job but two minutes not pass yet" do
      skip_if_frozen
      expect(github_runner).to receive(:workflow_job).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 1 * 60)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys the runner if the runner-script is succeeded" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("exited")
      expect(github_runner).to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "provisions a spare runner and destroys the current one if the runner-script is failed" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("failed")
      expect(github_runner).to receive(:provision_spare_runner)
      expect(github_runner).to receive(:incr_destroy)
      expect { nx.wait }.to nap(0)
    end

    it "naps if the runner-script is running" do
      expect(github_runner).to receive(:workflow_job).and_return({"id" => 123})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")

      expect { nx.wait }.to nap(15)
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
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)

      expect(github_runner).to receive(:workflow_job).and_return({"conclusion" => "failure"}).at_least(:once)
      vm_host = instance_double(VmHost, sshable: sshable)
      fws = [instance_double(Firewall)]
      ps = instance_double(PrivateSubnet, firewalls: fws)
      expect(fws.first).to receive(:destroy)
      expect(ps).to receive(:incr_destroy)
      expect(vm).to receive(:private_subnets).and_return([ps])
      expect(vm).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect(sshable).to receive(:cmd).with("sudo ln /vm/9qf22jbv/serial.log /var/log/ubicloud/serials/#{github_runner.ubid}_serial.log")
      expect(sshable).to receive(:cmd).with("journalctl -u runner-script --no-pager | grep -v -e Started -e sudo")
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "skip deregistration and destroy vm immediately" do
      expect(nx).to receive(:decr_destroy)
      expect(github_runner).to receive(:skip_deregistration_set?).and_return(true)
      expect(github_runner).to receive(:workflow_job).and_return({"conclusion" => "success"}).at_least(:once)
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "destroys resources and hops if runner deregistered, also, copies serial log if workflow_job is nil" do
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)

      expect(github_runner).to receive(:workflow_job).and_return(nil)
      vm_host = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect(sshable).to receive(:cmd).with("sudo ln /vm/9qf22jbv/serial.log /var/log/ubicloud/serials/#{github_runner.ubid}_serial.log")
      expect(sshable).to receive(:cmd).with("journalctl -u runner-script --no-pager | grep -v -e Started -e sudo")
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "destroys resources and hops if runner deregistered, also, emits log if it couldn't move the serial.log" do
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)

      expect(github_runner).to receive(:workflow_job).and_return({"conclusion" => "failure"}).at_least(:once)
      vm_host = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect(sshable).to receive(:cmd).and_raise Sshable::SshError.new("bogus", "", "", nil, nil)
      expect(Clog).to receive(:emit).with("Failed to move serial.log or running journalctl").and_call_original
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "simply destroys the VM if the workflow_job is there and the conclusion is success" do
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)

      expect(github_runner).to receive(:workflow_job).and_return({"conclusion" => "success"}).at_least(:once)
      expect(sshable).not_to receive(:cmd).with("sudo ln /vm/9qf22jbv/serial.log /var/log/ubicloud/serials/#{github_runner.ubid}_serial.log")
      expect(sshable).not_to receive(:cmd).with("journalctl -u runner-script --no-pager | grep -v -e Started -e sudo")
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "does not destroy vm if it's already destroyed" do
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
      expect(github_runner).to receive(:vm).and_return(nil)
      expect(vm).not_to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end
  end

  describe "#wait_vm_destroy" do
    it "naps if vm not destroyed yet" do
      expect { nx.wait_vm_destroy }.to nap(10)
    end

    it "extends deadline if vm prevents destroy" do
      expect(vm).to receive(:prevent_destroy_set?).and_return(true)
      expect(nx).to receive(:register_deadline).with(nil, 15 * 60, allow_extension: true)
      expect { nx.wait_vm_destroy }.to nap(10)
    end

    it "pops if vm destroyed" do
      expect(nx).to receive(:vm).and_return(nil).twice
      expect(github_runner).to receive(:destroy)

      expect { nx.wait_vm_destroy }.to exit({"msg" => "github runner deleted"})
    end
  end
end
