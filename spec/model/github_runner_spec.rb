# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GithubRunner do
  subject(:github_runner) {
    ins = GithubInstallation.create_with_id(installation_id: 123, name: "test-installation", type: "User")
    vm = create_vm(vm_host: create_vm_host, boot_image: "github-ubuntu-2204")
    Sshable.create { it.id = vm.id }
    described_class.create_with_id(repository_name: "test-repo", label: "ubicloud", vm_id: vm.id, installation_id: ins.id)
  }

  def clog_emit_hash
    hash = nil
    message = "runner_tested"
    expect(Clog).to(receive(:emit).with(message).and_wrap_original do |original_method, *args, &block|
      hash = block.call
      original_method.call(*args, &block)
    end)
    github_runner.log_duration(message, 10)
    hash[message]
  end

  it "can log duration with a vm" do
    vm = github_runner.vm
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center
    })
  end

  it "can log duration when it's from a vm pool" do
    pool = VmPool.create_with_id(size: 1, vm_size: "standard-2", location_id: Location::HETZNER_FSN1_ID, boot_image: "github-ubuntu-2204", storage_size_gib: 86)
    vm = github_runner.vm
    vm.update(pool_id: pool.id)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
      vm_pool_ubid: pool.ubid
    })
  end

  it "can log duration when vm does not have vm_host" do
    github_runner.vm.update(vm_host_id: nil)
    vm = github_runner.vm
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      cores: vm.cores,
      vcpus: vm.vcpus
    })
  end

  it "can log duration with a vm with a strand" do
    vm = github_runner.vm
    Strand.create(
      prog: "Vm::Nexus",
      label: "start",
      stack: [{"ch_version" => "46.0"}]
    ) { it.id = vm.id }
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
      ch_version: "46.0"
    })
  end

  it "can log duration without a vm" do
    github_runner.update(vm_id: nil)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil
    })
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
