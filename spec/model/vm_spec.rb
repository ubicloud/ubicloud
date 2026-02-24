# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vm do
  subject(:vm) { described_class.new(display_state: "creating", created_at: Time.now) }

  describe "#display_state" do
    let(:vm) {
      v = create_vm(display_state: "creating")
      Strand.create_with_id(v, prog: "Vm::Nexus", label: "wait")
      v
    }

    it "returns deleting if destroy semaphore increased" do
      vm.incr_destroy
      expect(vm.display_state).to eq("deleting")
    end

    it "returns deleting if destroying semaphore increased" do
      vm.incr_destroying
      expect(vm.display_state).to eq("deleting")
    end

    it "returns restarting if restart semaphore increased" do
      vm.incr_restart
      expect(vm.display_state).to eq("restarting")
    end

    it "returns stopped if stop semaphore increased" do
      vm.incr_stop
      expect(vm.display_state).to eq("stopped")
    end

    it "returns waiting for capacity if semaphore increased" do
      vm.incr_waiting_for_capacity
      expect(vm.display_state).to eq("waiting for capacity")
    end

    it "returns no capacity available if it's waiting capacity more than 15 minutes" do
      vm.update(created_at: Time.now - 16 * 60)
      vm.incr_waiting_for_capacity
      expect(vm.display_state).to eq("no capacity available")
    end

    it "return same if semaphores not increased" do
      expect(vm.display_state).to eq("creating")
    end
  end

  describe "#load_balancer_state" do
    it "returns nil if there is related object" do
      expect(vm.load_balancer_state).to be_nil
    end
  end

  describe "#cloud_hypervisor_cpu_topology" do
    it "scales a single-socket hyperthreaded system" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 6, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "standard", vcpus: 4)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "scales a dual-socket hyperthreaded system" do
      vmh = create_vm_host(total_cpus: 24, total_cores: 12, total_dies: 2, total_sockets: 2)
      vm = create_vm(vm_host_id: vmh.id, family: "standard", vcpus: 4)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "crashes if total_cpus is not multiply of total_cores" do
      vmh = create_vm_host(total_cpus: 3, total_cores: 2, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "standard", vcpus: 2)
      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if total_dies is not a multiple of total_sockets" do
      vmh = create_vm_host(total_cpus: 24, total_cores: 12, total_dies: 3, total_sockets: 2)
      vm = create_vm(vm_host_id: vmh.id, family: "standard", vcpus: 4)
      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if cores allocated per die is not uniform number" do
      vmh = create_vm_host(total_cpus: 1, total_cores: 1, total_dies: 1, total_sockets: 1, used_cores: 0)
      vm = create_vm(vm_host_id: vmh.id, family: "standard", vcpus: 4)
      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG: need uniform number of cores allocated per die"
    end

    it "crashes if the vcpus is an odd number" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 6, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "burstable", vcpus: 5)
      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG: need uniform number of cores allocated per die"
    end

    it "scales a single-socket non-hyperthreaded system" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 12, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "standard", vcpus: 4)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:4:1:1")
    end

    it "scales a single-socket hyperthreaded system for burstable family for 2 vcpus" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 6, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "burstable", vcpus: 2)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:1:1:1")
    end

    it "scales a single-socket non-hyperthreaded system for burstable family for 2 vcpus" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 12, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "burstable", vcpus: 2)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:2:1:1")
    end

    it "scales a single-socket hyperthreaded system for burstable family for 1 vcpu" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 6, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "burstable", vcpus: 1)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:1:1:1")
    end

    it "scales a double-socket hyperthreaded system for burstable family for 1 vcpu" do
      vmh = create_vm_host(total_cpus: 24, total_cores: 12, total_dies: 2, total_sockets: 2)
      vm = create_vm(vm_host_id: vmh.id, family: "burstable", vcpus: 1)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:1:1:1")
    end

    it "scales a single-socket non-hyperthreaded system for burstable family for 1 vcpu" do
      vmh = create_vm_host(total_cpus: 12, total_cores: 12, total_dies: 1, total_sockets: 1)
      vm = create_vm(vm_host_id: vmh.id, family: "burstable", vcpus: 1)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:1:1:1")
    end
  end

  describe "#update_spdk_version" do
    let(:vmh) { create_vm_host }
    let(:vm) {
      v = create_vm(vm_host_id: vmh.id)
      Strand.create_with_id(v, prog: "Vm::Nexus", label: "wait")
      v
    }

    it "can update spdk version" do
      spdk_installation = SpdkInstallation.create_with_id(vmh, version: "b", allocation_weight: 100, vm_host_id: vmh.id)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0)

      vm.update_spdk_version("b")

      expect(vm.vm_storage_volumes.first.spdk_installation_id).to eq(spdk_installation.id)
      expect(vm.reload.update_spdk_dependency_set?).to be true
    end

    it "fails if spdk installation not found" do
      expect { vm.update_spdk_version("b") }.to raise_error RuntimeError, "SPDK version b not found on host"
    end
  end

  describe "#utility functions" do
    let(:project) { Project.create(name: "test-util") }

    it "can compute the ipv4 addresses" do
      vm = create_vm(project_id: project.id)
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "1.1.1.0/32")
      expect(vm.ip4_string).to eq("1.1.1.0")
    end

    it "can compute nil if ipv4 is not assigned" do
      vm = create_vm(project_id: project.id)
      expect(vm.ip4).to be_nil
    end

    it "can compute the ipv6 addresses for non-aws location" do
      vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, ephemeral_net6: "2001:db8::/64")
      expect(vm.ip6_string).to eq("2001:db8::2")

      vm.update(ephemeral_net6: nil)
      expect(vm.ip6_string).to be_nil
    end

    it "can compute the ipv6 addresses for aws location" do
      aws_location = Location.create(name: "aws-test", display_name: "AWS Test", visible: false, provider: "aws", ui_name: "aws")
      vm = create_vm(project_id: project.id, location_id: aws_location.id, ephemeral_net6: "2001:db8::/128")
      expect(vm.ip6_string).to eq("2001:db8::")

      vm.update(ephemeral_net6: nil)
      expect(vm.ip6).to be_nil
    end

    it "returns the right private_ipv4 based on the netmask" do
      ps = PrivateSubnet.create(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10::/64", net4: "192.168.12.0/24", project_id: project.id)
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic-1", ipv4_addr: "192.168.12.13").subject
      vm = create_vm(project_id: project.id, name: "vm-ipv4-test-1")
      nic.update(vm_id: vm.id)
      expect(vm.private_ipv4.to_s).to eq("192.168.12.13")

      ps2 = PrivateSubnet.create(name: "test-ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd11::/64", net4: "10.10.240.0/24", project_id: project.id)
      nic2 = Prog::Vnet::NicNexus.assemble(ps2.id, name: "test-nic-2", ipv4_addr: "10.10.240.1").subject
      vm2 = create_vm(project_id: project.id, name: "vm-ipv4-test-2")
      nic2.update(vm_id: vm2.id)
      expect(vm2.private_ipv4.to_s).to eq("10.10.240.1")
    end
  end

  it "checks underlying enum value when validating" do
    vm = create_vm
    expect(vm.valid?).to be true
    def vm.display_state
      "invalid"
    end
    expect(vm.valid?).to be true
  end

  it "disallows VM ubid format as name" do
    vm = described_class.new(name: described_class.generate_ubid.to_s)
    vm.validate
    expect(vm.errors[:name]).to eq ["cannot be exactly 26 numbers/lowercase characters starting with vm to avoid overlap with id format"]
  end

  it "allows postgres server ubid format as name" do
    vm = described_class.new(name: PostgresServer.generate_ubid.to_s)
    vm.validate
    expect(vm.errors[:name]).to be_nil
  end

  describe "#check_pulse" do
    let(:vmh) { create_vm_host }
    let(:pulse_vm) {
      v = create_vm(vm_host_id: vmh.id)
      Strand.create_with_id(v, prog: "Vm::Nexus", label: "wait")
      v
    }

    let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
    let(:pulse) { {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30} }

    context "when vm is not sshable" do
      it "checks inhost_name and dnsmasq services" do
        expected_cmd = "systemctl is-active #{pulse_vm.inhost_name} #{pulse_vm.inhost_name}-dnsmasq"
        expect(session[:ssh_session]).to receive(:_exec!).with(expected_cmd).and_return("active\nactive\n")
        expect(pulse_vm.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
      end

      it "checks volume services if present" do
        vbb = VhostBlockBackend.create(version: "v1", allocation_weight: 100, vm_host_id: vmh.id)
        vol = VmStorageVolume.create(vm_id: pulse_vm.id, disk_index: 0, size_gib: 10, boot: true, vhost_block_backend_id: vbb.id, vring_workers: 1)

        expected_cmd = "systemctl is-active #{pulse_vm.inhost_name} #{pulse_vm.inhost_name}-dnsmasq #{vol.vhost_backend_systemd_unit_name}"
        expect(session[:ssh_session]).to receive(:_exec!).with(expected_cmd).and_return("active\nactive\nactive\n")
        expect(pulse_vm.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
      end

      [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
        it "reraises the exception for exception class: #{ex.class}" do
          expect(session[:ssh_session]).to receive(:_exec!).and_raise(ex)
          expect { pulse_vm.check_pulse(session:, previous_pulse: "notnil") }.to raise_error(ex)
        end
      end
    end

    context "when vm is sshable" do
      it "checks only volume services if present" do
        vbb = VhostBlockBackend.create(version: "v1", allocation_weight: 100, vm_host_id: vmh.id)
        vol = VmStorageVolume.create(vm_id: pulse_vm.id, disk_index: 0, size_gib: 10, boot: true, vhost_block_backend_id: vbb.id, vring_workers: 1)

        expected_cmd = "systemctl is-active #{pulse_vm.inhost_name} #{pulse_vm.inhost_name}-dnsmasq #{vol.vhost_backend_systemd_unit_name}"
        expect(session[:ssh_session]).to receive(:_exec!).with(expected_cmd).and_return("active\nactive\nactive\n")
        expect(pulse_vm.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
      end

      it "skips volumes without vhost_block_backend" do
        spdk_installation = SpdkInstallation.create_with_id(vmh, version: "spdk1", allocation_weight: 100, cpu_count: 2, vm_host_id: vmh.id)
        VmStorageVolume.create(vm_id: pulse_vm.id, disk_index: 0, size_gib: 10, boot: true, spdk_installation_id: spdk_installation.id)

        expected_cmd = "systemctl is-active #{pulse_vm.inhost_name} #{pulse_vm.inhost_name}-dnsmasq"
        expect(session[:ssh_session]).to receive(:_exec!).with(expected_cmd).and_return("active\nactive\n")
        result = pulse_vm.check_pulse(session:, previous_pulse: pulse)
        expect(result[:reading]).to eq("up")
      end
    end

    it "returns down and increments checkup when a service is inactive" do
      expect(session[:ssh_session]).to receive(:_exec!).and_return("active\ninactive\n")
      result = pulse_vm.check_pulse(session:, previous_pulse: pulse)
      expect(result[:reading]).to eq("down")
      expect(pulse_vm.reload.checkup_set?).to be true
    end

    it "returns down and increments checkup on SSH error" do
      expect(session[:ssh_session]).to receive(:_exec!).and_raise Sshable::SshError
      result = pulse_vm.check_pulse(session:, previous_pulse: pulse)
      expect(result[:reading]).to eq("down")
      expect(pulse_vm.reload.checkup_set?).to be true
    end
  end

  it "includes init_script in params_json if set" do
    project_id = Project.create(name: "test").id
    vmh = create_vm_host(total_cpus: 12, total_cores: 12, total_dies: 1, total_sockets: 1, accepts_slices: true)
    vm = Prog::Vm::Nexus.assemble("a a", project_id).subject
    vm.update(vm_host_id: vmh.id)

    expect(JSON.parse(vm.params_json)["init_script"]).to eq ""
    VmInitScript.create_with_id(vm, init_script: "c")
    expect(JSON.parse(vm.reload.params_json)["init_script"]).to eq "c"
  end

  describe "#storage_volumes" do
    let(:total_cpus) { 16 }
    let(:vm_host) { create_vm_host(accepts_slices: true, total_cpus:, total_cores: 8, total_dies: 4, total_sockets: 2) }
    let(:spdk_installation) { SpdkInstallation.create_with_id(vm_host.id, vm_host_id: vm_host.id, version: "spdk1", allocation_weight: 100, cpu_count: 2) }
    let(:storage_device) { StorageDevice.create(vm_host_id: vm_host.id, name: "default", available_storage_gib: 200, total_storage_gib: 200) }
    let(:boot_image) { BootImage.create(name: "boot_image", version: "1", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 1) }
    let(:kek) { StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "testkey", init_vector: "iv", auth_data: "auth") }
    let(:vbb) { VhostBlockBackend.create(version: "v0.1-5", allocation_weight: 100, vm_host_id: vm_host.id) }
    let(:vm) { create_vm(vm_host_id: vm_host.id) }

    before do
      spdk_installation
      storage_device
      boot_image

      VmStorageVolume.create(
        vm_id: vm.id, disk_index: 0, size_gib: 1, boot: true,
        boot_image_id: boot_image.id, key_encryption_key_1_id: kek.id,
        spdk_installation_id: spdk_installation.id, use_bdev_ubi: false,
        storage_device_id: storage_device.id
      )
      VmStorageVolume.create(
        vm_id: vm.id, disk_index: 1, size_gib: 100, boot: false,
        spdk_installation_id: spdk_installation.id, use_bdev_ubi: true,
        storage_device_id: storage_device.id, max_read_mbytes_per_sec: 200,
        max_write_mbytes_per_sec: 300, vhost_block_backend_id: vbb.id, vring_workers: 4
      )

      (0..total_cpus - 1).each do |cpu|
        VmHostCpu.create(
          vm_host_id: vm_host.id,
          cpu_number: cpu,
          spdk: cpu < vm_host.spdk_cpu_count
        )
      end
    end

    it "returns storage volumes hash list" do
      expected_device_id_0 = "#{vm.inhost_name}_0"
      expected_device_id_1 = "#{vm.inhost_name}_1"
      expect(vm.storage_volumes).to eq([
        {"boot" => true, "image" => "boot_image", "image_version" => "1", "size_gib" => 1,
         "device_id" => expected_device_id_0, "disk_index" => 0, "encrypted" => true,
         "spdk_version" => "spdk1", "use_bdev_ubi" => false,
         "storage_device" => "default", "read_only" => false,
         "max_read_mbytes_per_sec" => nil,
         "max_write_mbytes_per_sec" => nil,
         "vhost_block_backend_version" => nil, "num_queues" => 1, "queue_size" => 256,
         "copy_on_read" => false, "slice_name" => "system.slice"},
        {"boot" => false, "image" => nil, "image_version" => nil, "size_gib" => 100,
         "device_id" => expected_device_id_1, "disk_index" => 1, "encrypted" => false,
         "spdk_version" => "spdk1", "use_bdev_ubi" => true,
         "storage_device" => "default", "read_only" => false,
         "max_read_mbytes_per_sec" => 200,
         "max_write_mbytes_per_sec" => 300,
         "vhost_block_backend_version" => "v0.1-5", "num_queues" => 4, "queue_size" => 64,
         "copy_on_read" => false, "slice_name" => "system.slice"}
      ])
    end

    it "adds the cpus field to the params json when needed" do
      vm_host.update(accepts_slices: false)
      VmStorageVolume.where(vm_id: vm.id).update(spdk_installation_id: nil)
      vm_host.spdk_installations.first.destroy
      storage_volumes = vm.storage_volumes
      expect(storage_volumes[0]["cpus"].count).to eq(1)
      expect(storage_volumes[1]["cpus"].sort).to eq([0, 1])
    end
  end

  describe "#save_with_ephemeral_net6_error_retrying" do
    let(:project) { Project.create(name: "test") }
    let(:vm) { Prog::Vm::Nexus.assemble("a a", project.id).subject }
    let(:vm2) { Prog::Vm::Nexus.assemble("a a", project.id).subject }
    let(:vm_host) { create_vm_host(net6: "fd80:1:2::/48") }

    it "saves object if there are no exceptions raised" do
      assigned_net6 = vm_host.ip6_random_vm_network.to_s
      vm.ephemeral_net6 = assigned_net6
      expect(vm_host).not_to receive(:ip6_random_vm_network)
      vm.save_with_ephemeral_net6_error_retrying(vm_host)
      expect(vm.reload.ephemeral_net6.to_s).to eq(assigned_net6)
    end

    it "retries if there is a Sequel::ValidationFailed exception where the only error is for ephemeral_net6" do
      collision_net6 = vm_host.ip6_random_vm_network.to_s
      vm2.ephemeral_net6 = vm.ephemeral_net6 = collision_net6
      vm2.save_changes
      expect(vm_host).to receive(:ip6_random_vm_network).and_call_original
      vm.save_with_ephemeral_net6_error_retrying(vm_host)
      saved_net6 = vm.reload.ephemeral_net6
      expect(saved_net6.to_s).not_to eq(collision_net6)
      expect(vm_host.net6.rel(saved_net6)).to eq(1)  # generated address is within host's network
      expect(saved_net6.netmask.prefix_len).to eq(vm_host.net6.netmask.prefix_len + 15)  # /48 host -> /63 vm
    end

    it "raises for non-Sequel::ValidationFailed exceptions" do
      vm.ephemeral_net6 = vm_host.ip6_random_vm_network.to_s
      expect(vm_host).not_to receive(:ip6_random_vm_network)
      DB[:nic].where(vm_id: vm.id).delete
      DB[:vm].where(id: vm.id).delete
      expect { vm.save_with_ephemeral_net6_error_retrying(vm_host) }.to raise_error(Sequel::NoExistingObject)
    end

    it "raises for Sequel::ValidationFailed exceptions for other columns" do
      vm.project_id = nil
      expect(vm_host).not_to receive(:ip6_random_vm_network)
      expect { vm.save_with_ephemeral_net6_error_retrying(vm_host) }.to raise_error(Sequel::ValidationFailed)
    end

    it "raises instead of retrying more than max_retries times" do
      vm2.ephemeral_net6 = vm.ephemeral_net6 = vm_host.ip6_random_vm_network.to_s
      vm2.save_changes
      expect(vm_host).not_to receive(:ip6_random_vm_network)
      expect { vm.save_with_ephemeral_net6_error_retrying(vm_host, max_retries: 0) }.to raise_error(Sequel::ValidationFailed)
    end
  end

  describe "#params_json" do
    let(:project) { Project.create(name: "test-params-json") }
    let(:vmh) { create_vm_host(total_cpus: 4, total_cores: 4, total_dies: 1, total_sockets: 1, accepts_slices: true) }
    let(:ps) { PrivateSubnet.create(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd00::/64", net4: "10.0.0.0/24", project_id: project.id) }
    let(:nic) { Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject }
    let(:vm) { create_vm(project_id: project.id, vm_host_id: vmh.id, family: "standard", vcpus: 2) }
    let(:gpu_partition) { GpuPartition.create(vm_host_id: vmh.id, vm_id: vm.id, partition_id: 3, gpu_count: 1) }

    before do
      nic.update(vm_id: vm.id)
      gpu_partition
    end

    it "sets hypervisor to 'qemu' when a B200 GPU (device 2901) is present" do
      PciDevice.create(vm_host_id: vmh.id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "2901", numa_node: 0, iommu_group: 0)

      json = JSON.parse(vm.params_json)
      expect(json["hypervisor"]).to eq("qemu")
    end

    it "defaults hypervisor to 'ch' when no B200 GPU is present" do
      PciDevice.create(vm_host_id: vmh.id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "1234", numa_node: 0, iommu_group: 0)

      json = JSON.parse(vm.params_json)
      expect(json["hypervisor"]).to eq("ch")
    end

    it "respects an explicit hypervisor argument even if a B200 GPU is present" do
      PciDevice.create(vm_host_id: vmh.id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "2901", numa_node: 0, iommu_group: 0)

      json = JSON.parse(vm.params_json(hypervisor: "ch"))
      expect(json["hypervisor"]).to eq("ch")
    end

    it "includes the gpu partition id" do
      PciDevice.create(vm_host_id: vmh.id, vm_id: vm.id, slot: "00:00.0", device_class: "0300", vendor: "nvidia", device: "2901", numa_node: 0, iommu_group: 0)

      json = JSON.parse(vm.params_json)
      expect(json["gpu_partition_id"]).to eq(3)
    end
  end

  describe "#private_ipv4_string" do
    it "includes the private IPv4 address as a string" do
      vm.define_singleton_method(:private_ipv4) { NetAddr.parse_ip("1.1.1.0") }
      expect(vm.private_ipv4_string).to eq "1.1.1.0"
    end
  end

  describe "#private_ipv6_string" do
    it "includes the private IPv6 address as a string" do
      vm.define_singleton_method(:private_ipv6) { NetAddr.parse_ip("::2") }
      expect(vm.private_ipv6_string).to eq "::2"
    end
  end
end
