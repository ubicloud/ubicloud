# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GithubRunner do
  subject(:github_runner) {
    ins = GithubInstallation.create_with_id(installation_id: 123, name: "test-installation", type: "User")
    vm = create_vm(vm_host: create_vm_host, boot_image: "github-ubuntu-2204")
    Sshable.create { _1.id = vm.id }
    described_class.create_with_id(repository_name: "test-repo", label: "ubicloud", vm_id: vm.id, installation_id: ins.id)
  }

  it "can log duration when it's from a vm pool" do
    pool = VmPool.create_with_id(size: 1, vm_size: "standard-2", location: "hetzner-fsn1", boot_image: "github-ubuntu-2204", storage_size_gib: 86)
    github_runner.vm.update(pool_id: pool.id)
    expect(Clog).to receive(:emit).with("runner_tested").and_call_original
    github_runner.log_duration("runner_tested", 10)
  end

  it "can log duration without a vm" do
    github_runner.update(vm_id: nil)
    expect(Clog).to receive(:emit).with("runner_tested").and_call_original
    github_runner.log_duration("runner_tested", 10)
  end

  it "provisions a spare runner" do
    expect(Prog::Vm::GithubRunner).to receive(:assemble)
      .with(github_runner.installation, repository_name: github_runner.repository_name, label: github_runner.label)
      .and_return(instance_double(Strand, subject: instance_double(described_class)))
    github_runner.provision_spare_runner
  end

  it "initiates a new health monitor session" do
    expect(github_runner.vm.sshable).to receive(:start_fresh_session)
    github_runner.init_health_monitor_session
  end

  it "checks pulse when not destroying" do
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

  it "checks pulse when destroying" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(github_runner).to receive(:destroy_set?).and_return(true)
    expect(github_runner.check_pulse(session: session, previous_pulse: pulse)).to be_nil

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(github_runner).to receive(:destroy_set?).and_return(false)
    expect(github_runner).to receive(:strand).and_return(instance_double(Strand, label: "wait_vm_destroy"))
    expect(github_runner.check_pulse(session: session, previous_pulse: pulse)).to be_nil

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(github_runner).to receive(:destroy_set?).and_return(false)
    expect(github_runner).to receive(:strand).and_return(instance_double(Strand, label: "destroy"))
    expect(github_runner.check_pulse(session: session, previous_pulse: pulse)).to be_nil

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(github_runner).to receive(:destroy_set?).and_return(false)
    expect(github_runner).to receive(:strand).and_return(nil).at_least(:once)
    expect(Time).to receive(:now).and_return(pulse[:reading_chg] + 31)
    expect(github_runner.check_pulse(session: session, previous_pulse: pulse)).to eq(available_memory: nil, reading: "down", reading_rpt: 1, reading_chg: pulse[:reading_chg] + 31)
  end
end
