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
    GithubRunner.new(installation_id: "", repository_name: "test-repo", label: "ubicloud", ready_at: Time.now).tap {
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
    allow(vm).to receive(:sshable).and_return(sshable)
  end

  describe ".assemble" do
    it "creates github runner and vm with sshable" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")

      st = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud")

      runner = GithubRunner[st.id]
      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.label).to eq("ubicloud")
    end

    it "creates github runner with custom size" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
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

  describe ".storage_params" do
    it "returns the values returned by the storage_policy" do
      storage_policy_params = {
        "use_bdev_ubi_rate" => 0.1,
        "skip_sync_rate" => 0.2
      }
      project = Project.create_with_id(name: "sample project")
      project.set_github_storage_policy(storage_policy_params)
      expect(github_runner.installation).to receive(:project).and_return(project)
      storage_policy = instance_double(GithubStoragePolicy)
      expect(GithubStoragePolicy).to receive(:new).with(storage_policy_params).and_return(storage_policy)
      expect(storage_policy).to receive_messages(use_bdev_ubi?: false, skip_sync?: true)
      expect(nx.storage_params(5)).to eq({
        size_gib: 5,
        encrypted: false,
        use_bdev_ubi: false,
        skip_sync: true
      })
    end
  end

  describe ".pick_vm" do
    let(:project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

    before do
      runner_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:github_runner_service_project_id).and_return(runner_project.id)
      expect(github_runner).to receive(:label).and_return("ubicloud-standard-4").at_least(:once)
    end

    it "provisions a VM if the pool is not existing" do
      expect(VmPool).to receive(:where).and_return([])
      expect(Prog::Vm::Nexus).to receive(:assemble).and_call_original
      expect(Clog).to receive(:emit).with("Pool is empty").and_call_original
      expect(FirewallRule).to receive(:create_with_id).and_call_original.at_least(:once)
      expect(nx).to receive(:storage_params).and_return({encrypted: true, use_bdev_ubi: true, skip_sync: true})
      vm = nx.pick_vm
      expect(vm).not_to be_nil
      expect(vm.sshable.unix_user).to eq("runner")
      expect(vm.family).to eq("standard")
      expect(vm.cores).to eq(2)
      expect(vm.projects.map(&:id)).to include(Config.github_runner_service_project_id)
    end

    it "provisions a new vm if pool is valid but there is no vm" do
      git_runner_pool = VmPool.create_with_id(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners", storage_size_gib: 150)
      expect(VmPool).to receive(:where).with(vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners", storage_size_gib: 150).and_return([git_runner_pool])
      expect(git_runner_pool).to receive(:pick_vm).and_return(nil)
      expect(Prog::Vm::Nexus).to receive(:assemble).and_call_original
      expect(Clog).to receive(:emit).with("Pool is empty").and_call_original
      expect(FirewallRule).to receive(:create_with_id).and_call_original.at_least(:once)
      expect(nx).to receive(:storage_params).and_return({encrypted: false, use_bdev_ubi: false})
      vm = nx.pick_vm
      expect(vm).not_to be_nil
      expect(vm.sshable.unix_user).to eq("runner")
      expect(vm.family).to eq("standard")
      expect(vm.cores).to eq(2)
    end

    it "uses the existing vm if pool can pick one" do
      git_runner_pool = VmPool.create_with_id(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners", storage_size_gib: 150)
      expect(VmPool).to receive(:where).with(vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners", storage_size_gib: 150).and_return([git_runner_pool])
      expect(git_runner_pool).to receive(:pick_vm).and_return(vm)
      expect(Clog).to receive(:emit).with("Pool is used").and_call_original
      vm = nx.pick_vm
      expect(vm).not_to be_nil
      expect(vm.name).to eq("dummy-vm")
    end
  end

  describe ".update_billing_record" do
    let(:project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

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
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(github_runner).to receive(:ready_at).and_return(time - 5 * 60).at_least(:once)
      expect(BillingRecord).to receive(:create_with_id).and_call_original
      nx.update_billing_record

      br = BillingRecord[resource_id: project.id]
      expect(br.amount).to eq(5)
      expect(br.duration(time, time)).to eq(1)
    end

    it "updates the amount of existing billing record" do
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
      today = Time.now
      tomorrow = today + 24 * 60 * 60
      expect(Time).to receive(:now).and_return(today).exactly(4)
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
    it "picks vm and hops" do
      expect(nx).to receive(:pick_vm).and_return(vm)
      expect(github_runner).to receive(:update).with(vm_id: vm.id)
      expect(vm).to receive(:update).with(name: github_runner.ubid)
      expect { nx.start }.to hop("wait_vm")
    end
  end

  describe "#wait_vm" do
    it "naps if vm not ready" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "prep"))
      expect(nx).not_to receive(:pick_vm)
      expect { nx.wait_vm }.to nap(5)
    end

    it "hops if vm is ready" do
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect { nx.wait_vm }.to hop("setup_environment")
    end
  end

  describe "#setup_environment" do
    it "hops to register_runner" do
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        sudo usermod -a -G docker,adm,systemd-journal runner
        sudo su -c "find /opt/post-generation -mindepth 1 -maxdepth 1 -type f -name '*.sh' -exec bash {} ';'"
        source /etc/environment
        sudo [ ! -d /usr/local/share/actions-runner ] || sudo mv /usr/local/share/actions-runner ./
        sudo chown -R runner:runner actions-runner
        ./actions-runner/env.sh
        echo "PATH=$PATH" >> ./actions-runner/.env
      COMMAND

      expect { nx.setup_environment }.to hop("register_runner")
    end
  end

  describe "#register_runner" do
    it "registers runner hops" do
      expect(client).to receive(:post).with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label])).and_return({runner: {id: 123}, encoded_jit_config: "AABBCC"})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("dead")
      expect(sshable).to receive(:cmd).with("sudo -- xargs -I{} -- systemd-run --uid runner --gid runner --working-directory '/home/runner' --unit runner-script --remain-after-exit -- ./actions-runner/run.sh --jitconfig {}",
        stdin: "AABBCC")
      expect(github_runner).to receive(:update).with(runner_id: 123, ready_at: anything)

      expect { nx.register_runner }.to hop("wait")
    end

    it "deletes the runner if the generate request fails due to 'already exists with the same name' error." do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("dead")
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate)
        .and_yield({runners: [{name: github_runner.ubid.to_s, id: 123}]}, instance_double(Sawyer::Response, data: {runners: []}))
        .and_return({runners: [{name: github_runner.ubid.to_s, id: 123}]})
      expect(client).to receive(:delete).with("/repos/#{github_runner.repository_name}/actions/runners/123")
      expect(Clog).to receive(:emit).with("Deleting GithubRunner because it already exists").and_call_original
      expect { nx.register_runner }.to nap(5)
    end

    it "naps if the generate request fails due to 'already exists with the same name' error but couldn't find the runner" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("dead")
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Already exists - A runner with the name *** already exists."}))
      expect(client).to receive(:paginate).and_return({runners: []})
      expect(client).not_to receive(:delete)
      expect { nx.register_runner }.to raise_error RuntimeError, "BUG: Failed with runner already exists error but couldn't find it"
    end

    it "fails if the generate request fails due to 'Octokit::Conflict' but it's not already exists error" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("dead")
      expect(client).to receive(:post)
        .with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
        .and_raise(Octokit::Conflict.new({body: "409 - Another issue"}))
      expect { nx.register_runner }.to raise_error Octokit::Conflict
    end

    it "hops to wait if the runner-script is started already" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(client).not_to receive(:post).with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label]))
      expect(sshable).not_to receive(:cmd).with(/sudo systemd-run --uid runner --gid runner.*/)

      expect { nx.register_runner }.to hop("wait")
    end
  end

  describe "#wait" do
    it "does not destroy runner if it does not pick a job in two minutes, and busy" do
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 3 * 60)
      expect(client).to receive(:get).and_return({busy: true})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys runner if it does not pick a job in two minutes and not busy" do
      expect(github_runner).to receive(:workflow_job).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 3 * 60)
      expect(client).to receive(:get).and_return({busy: false})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).to receive(:incr_destroy)
      expect(Clog).to receive(:emit).with("Destroying GithubRunner because it does not pick a job in two minutes").and_call_original

      expect { nx.wait }.to nap(0)
    end

    it "does not destroy runner if it doesn not pick a job but two minutes not pass yet" do
      expect(github_runner).to receive(:workflow_job).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 1 * 60)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys the runner if the runner-script is succeeded" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("exited")
      expect(github_runner).to receive(:incr_destroy)

      expect { nx.wait }.to nap(0)
    end

    it "cleans and registers the runner again if the runner-script is failed" do
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("failed")
      expect(client).to receive(:delete)
      expect(github_runner).to receive(:update).with(runner_id: nil, ready_at: nil)

      expect { nx.wait }.to hop("register_runner")
    end

    it "naps if the runner-script is running" do
      expect(github_runner).to receive(:workflow_job).and_return({"id" => 123})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")

      expect { nx.wait }.to nap(15)
    end
  end

  describe "#destroy" do
    it "naps if runner not deregistered yet" do
      expect(client).to receive(:get)
      expect(client).to receive(:delete)

      expect { nx.destroy }.to nap(5)
    end

    it "destroys resources and hops if runner deregistered" do
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
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

    it "pops if vm destroyed" do
      expect(nx).to receive(:vm).and_return(nil)
      expect(github_runner).to receive(:destroy)

      expect { nx.wait_vm_destroy }.to exit({"msg" => "github runner deleted"})
    end
  end
end
