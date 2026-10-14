# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRunner do
  subject(:github_runner) {
    ins = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
    vm = create_vm(vm_host: create_vm_host, boot_image: "github-ubuntu-2204")
    Sshable.create_with_id(vm)
    described_class.create(repository_name: "test-repo", label: "ubicloud", vm_id: vm.id, location_id: vm.location_id, installation_id: ins.id)
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

  describe "capacity" do
    let(:runner) { described_class.create(repository_name: "test-repo", label: "ubicloud-standard-4", installation_id: GithubInstallation.create(installation_id: 456, name: "capacity", type: "User").id) }
    let(:pool) { GithubRunnerCapacity["x64-standard"].update(total_cores: 100, total_hugepages_1g: 400) }
    let(:spill) { GithubRunnerCapacity[GithubRunnerCapacity::SPILL] }

    before { pool }

    def usage(row)
      row.reload.values.values_at(:used_cores, :used_hugepages_1g, :used_vcpus, :used_runners)
    end

    it "charges metal capacity by cores and hugepages, and spill capacity by AWS vCPUs" do
      expect(runner.metal_capacity_pool).to eq("x64-standard")
      expect(runner.capacity_amounts("x64-standard")).to eq({used_cores: 2, used_hugepages_1g: 16})
      expect(runner.capacity_amounts(GithubRunnerCapacity::SPILL)).to eq({used_vcpus: 4, used_runners: 1})
      runner.update(label: "ubicloud-standard-30-arm")
      runner.instance_variable_set(:@label_data, nil)
      expect(runner.metal_capacity_pool).to eq("arm64-standard")
      expect(runner.capacity_amounts("arm64-standard")).to eq({used_cores: 30, used_hugepages_1g: 96})
      expect(runner.capacity_amounts(GithubRunnerCapacity::SPILL)).to eq({used_vcpus: 32, used_runners: 1})
    end

    it "reserves metal capacity within the utilization" do
      expect(runner.reserve_metal_capacity(95)).to be(true)
      expect(runner.reload.capacity_pool).to eq("x64-standard")
      expect(usage(pool)).to eq([2, 16, 0, 0])
    end

    it "does not reserve metal capacity past the utilization" do
      pool.update(used_cores: 95)
      expect(runner.reserve_metal_capacity(95)).to be(false)
      expect(runner.reload.capacity_pool).to be_nil
      expect(usage(pool)).to eq([95, 0, 0, 0])
    end

    it "rolls the move back when the pool fills up after the read" do
      charged = nil
      expect(GithubRunnerCapacity).to receive(:charge).and_wrap_original do |original, *args|
        # Another runner fills the pool between the read and the charge.
        pool.update(used_cores: 95)
        charged = original.call(*args)
      end
      expect(runner.reserve_metal_capacity(95)).to be_nil
      expect(charged).to be(false)
      expect(runner.reload.capacity_pool).to be_nil
    end

    it "moves a metal reservation to spill capacity and back" do
      runner.reserve_metal_capacity(95)
      expect(runner.reserve_spill_capacity).to be(true)
      expect(runner.reload.capacity_pool).to eq(GithubRunnerCapacity::SPILL)
      expect(usage(pool)).to eq([0, 0, 0, 0])
      expect(usage(spill)).to eq([0, 0, 4, 1])

      expect(runner.move_capacity("x64-standard")).to be(true)
      expect(usage(pool)).to eq([2, 16, 0, 0])
      expect(usage(spill)).to eq([0, 0, 0, 0])
    end

    it "keeps the reservation it already holds" do
      runner.reserve_metal_capacity(95)
      expect(runner.move_capacity("x64-standard")).to be(true)
      expect(usage(pool)).to eq([2, 16, 0, 0])
    end

    it "releases the reservation" do
      runner.reserve_spill_capacity
      runner.release_capacity
      expect(runner.reload.capacity_pool).to be_nil
      expect(usage(spill)).to eq([0, 0, 0, 0])
      expect(runner.release_capacity).to be_nil
    end
  end

  describe ".adopt_capacity" do
    let(:installation) { GithubInstallation.create(installation_id: 457, name: "adopt", type: "User") }

    def runner(label: "wait", location_id: Location::GITHUB_RUNNERS_ID, vm: true, **)
      vm_id = create_vm(location_id:).id if vm
      described_class.create(installation_id: installation.id, repository_name: "test-repo", label: "ubicloud-standard-4", vm_id:, location_id: (location_id if vm), **).tap {
        Strand.create_with_id(it, prog: "Github::GithubRunnerNexus", label:)
      }
    end

    it "gives a pool to runners that hold a VM without a reservation" do
      location = Location.create(name: "eu-central-1", provider: "aws", project_id: Project.create(name: "aws").id, display_name: "aws-eu-central-1", ui_name: "AWS Frankfurt", visible: true)
      expect(Config).to receive(:github_runner_aws_location_id).and_return(location.id)
      metal = runner
      aws = runner(location_id: location.id)
      reserved = runner(capacity_pool: "x64-premium")
      waiting = runner(vm: false)
      leaving = runner(label: "wait_vm_destroy")

      expect(described_class.adopt_capacity).to eq(2)
      expect([metal, aws, reserved, waiting, leaving].map { it.reload.capacity_pool }).to eq(["x64-standard", GithubRunnerCapacity::SPILL, "x64-premium", nil, nil])
    end
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
      data_center: vm.vm_host.data_center,
    })
  end

  it "can log duration with ch_version if the vm's strand has one" do
    vm = github_runner.vm
    Strand.create(prog: "Vm::Metal::Nexus", label: "start", stack: [{"ch_version" => "53.0"}]) { it.id = vm.id }
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
      ch_version: "53.0",
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
      vm_pool_ubid: pool.ubid,
    })
  end

  it "can log duration with vhost block backend version" do
    vm = github_runner.vm
    vhost_block_backend = create_vhost_block_backend(vm_host_id: vm.vm_host_id)
    boot_image = BootImage.create(vm_host_id: vm.vm_host_id, name: "github-ubuntu-2204", version: "20251211", size_gib: 75)
    VmStorageVolume.create(
      vm_id: vm.id,
      boot: true,
      size_gib: 75,
      disk_index: 0,
      boot_image_id: boot_image.id,
      vhost_block_backend_id: vhost_block_backend.id,
      vring_workers: 4,
    )

    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: boot_image.version,
      vhost_block_backend_version: vhost_block_backend.version,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
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
      vcpus: vm.vcpus,
    })
  end

  it "can log duration without a vm" do
    github_runner.update(vm_id: nil, location_id: nil)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
    })
  end

  it "provisions a spare runner and increments the spare_runner_provisioned semaphore" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")

    spare_runner = github_runner.provision_spare_runner

    expect(spare_runner).to be_a(described_class)
    expect(spare_runner.installation_id).to eq(github_runner.installation_id)
    expect(spare_runner.repository_name).to eq(github_runner.repository_name)
    expect(spare_runner.label).to eq(github_runner.label)
    expect(github_runner.spare_runner_provisioned_set?(cached: false)).to be(true)
  end

  it "does not provision another spare runner once one has been provisioned" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")
    github_runner.incr_spare_runner_provisioned

    expect {
      expect(github_runner.provision_spare_runner).to be_nil
    }.not_to change(described_class, :count)
  end

  it "provisions a spare runner regardless of the semaphore when force is true" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")
    github_runner.incr_spare_runner_provisioned

    expect {
      expect(github_runner.provision_spare_runner(force: true)).to be_a(described_class)
    }.to change(described_class, :count).from(1).to(2)
  end

  it "initiates a new health monitor session" do
    expect(github_runner.vm.sshable).to receive(:start_fresh_session)
    github_runner.init_health_monitor_session
  end

  it "does not page on sshable failure" do
    expect(github_runner.page_on_sshable_failure?).to be false
  end

  it "checks pulse" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30,
    }

    expect(session[:ssh_session]).to receive(:_exec!).with("awk '/MemAvailable/ {print $2}' /proc/meminfo").and_return("123\n")
    github_runner.check_pulse(session:, previous_pulse: pulse)

    expect(session[:ssh_session]).to receive(:_exec!).and_raise Sshable::SshError
    github_runner.check_pulse(session:, previous_pulse: pulse)
  end
end
