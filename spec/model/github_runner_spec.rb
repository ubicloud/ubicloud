# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GithubRunner do
  subject(:github_runner) {
    described_class.new(repository_name: "test-repo", label: "ubicloud").tap {
      _1.id = "ca2eb084-8a36-8618-a16f-7561d7faf3b6"
    }
  }

  let(:vm) { instance_double(Vm, sshable: instance_double(Sshable), cores: 2) }

  before do
    allow(github_runner).to receive_messages(installation: instance_double(GithubInstallation), vm: instance_double(Vm, arch: "x64", cores: 2, ubid: "vm-ubid", pool_id: "pool-id"))
    allow(github_runner.vm).to receive_messages(sshable: instance_double(Sshable), vm_host: instance_double(VmHost, ubid: "host-ubid"))
  end

  it "can log duration when it's from a vm pool" do
    expect(VmPool).to receive(:[]).with("pool-id").and_return(instance_double(VmPool, ubid: "pool-ubid"))
    expect(Clog).to receive(:emit).with("runner_tested").and_call_original
    github_runner.log_duration("runner_tested", 10)
  end

  it "can log duration without a vm" do
    expect(github_runner).to receive(:vm).and_return(nil)
    expect(Clog).to receive(:emit).with("runner_tested").and_call_original
    github_runner.log_duration("runner_tested", 10)
  end

  it "provisions a spare runner" do
    expect(Prog::Vm::GithubRunner).to receive(:assemble).with(github_runner.installation, repository_name: github_runner.repository_name, label: github_runner.label)
      .and_return(instance_double(Strand, subject: instance_double(described_class)))
    github_runner.provision_spare_runner
  end

  it "initiates a new health monitor session" do
    expect(github_runner.vm.sshable).to receive(:start_fresh_session)
    github_runner.init_health_monitor_session
  end

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:ssh_session]).to receive(:exec!).with("awk '/MemAvailable/ {print $2}' /proc/meminfo").and_return("123\n")
    github_runner.check_pulse(session: session, previous_pulse: pulse)

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    github_runner.check_pulse(session: session, previous_pulse: pulse)
  end
end
