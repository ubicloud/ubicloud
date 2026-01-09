# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRunner do
  subject(:github_runner) {
    ins = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
    vm = create_vm(vm_host: create_vm_host, boot_image: "github-ubuntu-2204")
    Sshable.create_with_id(vm)
    described_class.create(repository_name: "test-repo", label: "ubicloud", vm_id: vm.id, installation_id: ins.id)
  }

  def clog_emit_hash
    hash = nil
    message = "runner_tested"
    expect(Clog).to(receive(:emit).with(message, instance_of(Hash)).and_wrap_original do |original_method, *args, b|
      hash = b
      original_method.call(*args, hash)
    end)
    github_runner.log_duration(message, 10)
    hash[message]
  end

  it "can log duration with a vm" do
    vm = github_runner.vm
    boot_image = BootImage.create(vm_host_id: vm.vm_host_id, name: "github-ubuntu-2204", version: "20251211", size_gib: 75)
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 75, disk_index: 0, boot_image_id: boot_image.id)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: boot_image.version,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center
    })
  end

  it "can log duration when it's from a vm pool" do
    pool = VmPool.create(size: 1, vm_size: "standard-2", location_id: Location::HETZNER_FSN1_ID, boot_image: "github-ubuntu-2204", storage_size_gib: 86)
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
      boot_image: vm.boot_image,
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
    AwsInstance.create_with_id(vm.id, instance_id: "i-0123456789abcdefg")
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      instance_id: "i-0123456789abcdefg",
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: vm.boot_image,
      cores: vm.cores,
      vcpus: vm.vcpus
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
    spare_runner = github_runner.provision_spare_runner

    expect(spare_runner).to be_a(described_class)
    expect(spare_runner.installation_id).to eq(github_runner.installation_id)
    expect(spare_runner.repository_name).to eq(github_runner.repository_name)
    expect(spare_runner.label).to eq(github_runner.label)
  end

  it "initiates a new health monitor session" do
    expect(github_runner.vm.sshable).to receive(:start_fresh_session)
    github_runner.init_health_monitor_session
  end

  it "checks pulse" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:ssh_session]).to receive(:_exec!).with("awk '/MemAvailable/ {print $2}' /proc/meminfo").and_return("123\n")
    github_runner.check_pulse(session:, previous_pulse: pulse)

    expect(session[:ssh_session]).to receive(:_exec!).and_raise Sshable::SshError
    github_runner.check_pulse(session:, previous_pulse: pulse)
  end
end
