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
    Vm.new(family: "standard", cores: 1, name: "dummy-vm", location: "hetzner-hel1")
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
      expect(runner.vm.unix_user).to eq("runner")
      expect(runner.vm.sshable.unix_user).to eq("runner")
    end

    it "creates github runner with custom size" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")

      st = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud-standard-8")

      runner = GithubRunner[st.id]
      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.vm.unix_user).to eq("runner")
      expect(runner.vm.family).to eq("standard")
      expect(runner.vm.cores).to eq(4)
      expect(runner.vm.sshable.unix_user).to eq("runner")
    end

    it "fails if label is not valid" do
      expect {
        described_class.assemble(instance_double(GithubInstallation), repository_name: "test-repo", label: "ubicloud-standard-1")
      }.to raise_error RuntimeError, "Invalid GitHub runner label: ubicloud-standard-1"
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
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
    it "naps if vm not ready" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(sshable).to receive(:update).with(host: "1.1.1.1")
      expect { nx.start }.to hop("setup_environment")
    end
  end

  it "hops to install_actions_runner" do
    expect(sshable).to receive(:cmd).with("sudo usermod -a -G docker,adm,systemd-journal runner")
    expect(sshable).to receive(:cmd).with(/\/opt\/post-generation/)
    expect(sshable).to receive(:invalidate_cache_entry)
    expect(sshable).to receive(:cmd).with("sudo mv /usr/local/share/actions-runner ./")
    expect(sshable).to receive(:cmd).with("sudo chown -R runner:runner actions-runner")
    expect(sshable).to receive(:cmd).with("./actions-runner/env.sh")
    expect(sshable).to receive(:cmd).with("echo \"PATH=$PATH\" >> ./actions-runner/.env")

    expect { nx.setup_environment }.to hop("register_runner")
  end

  describe "#register_runner" do
    it "generates runner if not runner id not set and hops" do
      expect(github_runner).to receive(:runner_id).and_return(nil)
      expect(client).to receive(:post).with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label])).and_return({runner: {id: 123}, encoded_jit_config: "AABBCC"})
      expect(sshable).to receive(:cmd).with("sudo systemd-run --uid runner --gid runner --working-directory '/home/runner' --unit runner-script --remain-after-exit -- ./actions-runner/run.sh --jitconfig AABBCC")
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).to receive(:update).with(runner_id: 123, ready_at: anything)

      expect { nx.register_runner }.to hop("wait")
    end

    it "does not generate runner if runner exists and destroys it" do
      expect(github_runner).to receive(:runner_id).and_return(123).at_least(:once)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("failed")
      expect(client).to receive(:delete)
      expect(github_runner).to receive(:update).with(runner_id: nil, ready_at: nil)

      expect { nx.register_runner }.to nap(10)
    end

    it "naps if script return unknown status" do
      expect(github_runner).to receive(:runner_id).and_return(123).at_least(:once)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("unknown")

      expect { nx.register_runner }.to nap(10)
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
      expect(github_runner).to receive(:job_id).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 3 * 60)
      expect(client).to receive(:get).and_return({busy: false})
      expect(github_runner).to receive(:incr_destroy)

      expect do
        expect { nx.wait }.to nap(0)
      end.to output("GithubRunner[#{github_runner.ubid}] Not pick a job in two minutes, destroying it\n").to_stdout
    end

    it "does not destroy runner if it doesn not pick a job but two minutes not pass yet" do
      expect(github_runner).to receive(:job_id).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 1 * 60)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys runner if runner-script exited with Succeeded" do
      expect(github_runner).to receive(:job_id).and_return(123)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("exited")
      expect(github_runner).to receive(:incr_destroy)

      expect { nx.wait }.to nap(0)
    end

    it "naps" do
      expect(github_runner).to receive(:job_id).and_return(123)
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
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
      expect(sshable).to receive(:destroy)
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "does not destroy vm if it's already destroyed" do
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
      expect(github_runner).to receive(:vm).and_return(nil)
      expect(sshable).not_to receive(:destroy)
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
