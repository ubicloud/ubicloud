# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vm do
  subject(:vm) { described_class.new(display_state: "creating", created_at: Time.now) }

  describe "#display_state" do
    it "returns deleting if destroy semaphore increased" do
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "destroy")]).at_least(:once)
      expect(vm.display_state).to eq("deleting")
    end

    it "returns restarting if restart semaphore increased" do
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "restart")]).at_least(:once)
      expect(vm.display_state).to eq("restarting")
    end

    it "returns stopped if stop semaphore increased" do
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "stop")]).at_least(:once)
      expect(vm.display_state).to eq("stopped")
    end

    it "returns waiting for capacity if semaphore increased" do
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "waiting_for_capacity")]).at_least(:once)
      expect(vm.display_state).to eq("waiting for capacity")
    end

    it "returns no capacity available if it's waiting capacity more than 15 minutes" do
      expect(vm).to receive(:created_at).and_return(Time.now - 16 * 60)
      expect(vm).to receive(:semaphores).and_return([instance_double(Semaphore, name: "waiting_for_capacity")]).at_least(:once)
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
      vm.family = "standard"
      vm.vcpus = 4
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 6,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "scales a dual-socket hyperthreaded system" do
      vm.family = "standard"
      vm.vcpus = 4
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_dies: 2,
        total_sockets: 2
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:2:1:1")
    end

    it "crashes if total_cpus is not multiply of total_cores" do
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 3,
        total_cores: 2
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if total_dies is not a multiple of total_sockets" do
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_dies: 3,
        total_sockets: 2
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG"
    end

    it "crashes if cores allocated per die is not uniform number" do
      vm.family = "standard"
      vm.vcpus = 4

      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 1,
        total_cores: 1,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG: need uniform number of cores allocated per die"
    end

    it "crashes if the vcpus is an odd number" do
      vm.family = "burstable"
      vm.vcpus = 5
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 6,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)

      expect { vm.cloud_hypervisor_cpu_topology }.to raise_error RuntimeError, "BUG: need uniform number of cores allocated per die"
    end

    it "scales a single-socket non-hyperthreaded system" do
      vm.family = "standard"
      vm.vcpus = 4
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 12,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:4:1:1")
    end

    it "scales a single-socket hyperthreaded system for burstable family for 2 vcpus" do
      vm.family = "burstable"
      vm.vcpus = 2
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 6,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("2:1:1:1")
    end

    it "scales a single-socket non-hyperthreaded system for burstable family for 2 vcpus" do
      vm.family = "burstable"
      vm.vcpus = 2
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 12,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:2:1:1")
    end

    it "scales a single-socket hyperthreaded system for burstable family for 1 vcpu" do
      vm.family = "burstable"
      vm.vcpus = 1
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 6,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:1:1:1")
    end

    it "scales a double-socket hyperthreaded system for burstable family for 1 vcpu" do
      vm.family = "burstable"
      vm.vcpus = 1
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 24,
        total_cores: 12,
        total_dies: 2,
        total_sockets: 2
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:1:1:1")
    end

    it "scales a single-socket non-hyperthreaded system for burstable family for 1 vcpu" do
      vm.family = "burstable"
      vm.vcpus = 1
      expect(vm).to receive(:vm_host).and_return(instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 12,
        total_dies: 1,
        total_sockets: 1
      )).at_least(:once)
      expect(vm.cloud_hypervisor_cpu_topology.to_s).to eq("1:1:1:1")
    end
  end

  describe "#update_spdk_version" do
    let(:vmh) { create_vm_host }

    before do
      expect(vm).to receive(:vm_host).and_return(vmh)
    end

    it "can update spdk version" do
      spdk_installation = SpdkInstallation.create_with_id(vmh, version: "b", allocation_weight: 100, vm_host_id: vmh.id)
      volume_dataset = instance_double(Sequel::Dataset)
      expect(vm).to receive(:vm_storage_volumes_dataset).and_return(volume_dataset)
      expect(volume_dataset).to receive(:update).with(spdk_installation_id: spdk_installation.id)
      expect(vm).to receive(:incr_update_spdk_dependency)

      vm.update_spdk_version("b")
    end

    it "fails if spdk installation not found" do
      expect { vm.update_spdk_version("b") }.to raise_error RuntimeError, "SPDK version b not found on host"
    end
  end

  describe "#utility functions" do
    it "can compute the ipv4 addresses" do
      as_ad = instance_double(AssignedVmAddress, ip: NetAddr::IPv4Net.new(NetAddr.parse_ip("1.1.1.0"), NetAddr::Mask32.new(32)))
      expect(vm).to receive(:assigned_vm_address).and_return(as_ad).at_least(:once)
      expect(vm.ip4_string).to eq("1.1.1.0")
    end

    it "can compute nil if ipv4 is not assigned" do
      expect(vm.ip4).to be_nil
    end

    it "can compute the ipv6 addresses" do
      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: false)).twice
      expect(vm).to receive(:ephemeral_net6).and_return(NetAddr::IPv6Net.parse("2001:db8::/64"))
      expect(vm.ip6_string).to eq("2001:db8::2")

      expect(vm).to receive(:ephemeral_net6).and_return(nil)
      expect(vm.ip6_string).to be_nil

      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: true))
      expect(vm).to receive(:ephemeral_net6).and_return(NetAddr::IPv6Net.parse("2001:db8::/128"))
      expect(vm.ip6_string).to eq("2001:db8::")

      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: true))
      expect(vm).to receive(:ephemeral_net6).and_return(nil)
      expect(vm.ip6).to be_nil
    end

    it "returns the right private_ipv4 based on the netmask" do
      nic = instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("192.168.12.13/32"))
      expect(vm).to receive(:nics).and_return([nic])
      expect(vm.private_ipv4.to_s).to eq("192.168.12.13")

      nic = instance_double(Nic, private_ipv4: NetAddr.parse_net("10.10.240.0/24"))
      expect(vm).to receive(:nics).and_return([nic])
      expect(vm.private_ipv4.to_s).to eq("10.10.240.1")
    end
  end

  it "initiates a new health monitor session" do
    vh = instance_double(VmHost, sshable: instance_double(Sshable))
    expect(vm).to receive(:vm_host).and_return(vh).at_least(:once)
    expect(vh.sshable).to receive(:start_fresh_session)
    vm.init_health_monitor_session
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

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(vm).to receive(:inhost_name).and_return("vmxxxx").at_least(:once)
    expect(session[:ssh_session]).to receive(:exec!).and_return("active\nactive\n")
    expect(vm.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")

    expect(session[:ssh_session]).to receive(:exec!).and_return("active\ninactive\n")
    expect(vm).to receive(:reload).and_return(vm)
    expect(vm).to receive(:incr_checkup)
    expect(vm.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(vm).to receive(:reload).and_return(vm)
    expect(vm).to receive(:incr_checkup)
    expect(vm.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "includes init_script in params_json if set" do
    project_id = Project.create(name: "test").id
    vm = Prog::Vm::Nexus.assemble("a a", project_id).subject
    expect(vm).to receive(:vm_host).and_return(instance_double(
      VmHost,
      total_cpus: 12,
      total_cores: 12,
      total_dies: 1,
      total_sockets: 1,
      ndp_needed: false,
      spdk_installations: [],
      accepts_slices: true
    )).at_least(:once)
    expect(JSON.parse(vm.params_json)["init_script"]).to eq ""
    VmInitScript.create_with_id(vm, script: "b")
    expect(JSON.parse(vm.reload.params_json)["init_script"]).to eq "b"
  end

  describe "#storage_volumes" do
    let(:volumes) {
      boot_image = instance_double(BootImage, name: "boot_image", version: "1")
      storage_device = instance_double(StorageDevice, name: "default")
      [
        instance_double(VmStorageVolume, disk_index: 0, device_id: "dev1",
          size_gib: 1, boot: true, boot_image: boot_image,
          key_encryption_key_1: "key", spdk_version: "spdk1",
          use_bdev_ubi: false, skip_sync: false,
          storage_device: storage_device,
          max_read_mbytes_per_sec: nil, max_write_mbytes_per_sec: nil,
          vhost_block_backend_version: nil, num_queues: 1, queue_size: 256),
        instance_double(VmStorageVolume, disk_index: 1, device_id: "dev2",
          size_gib: 100, boot: false, boot_image: nil,
          key_encryption_key_1: nil, spdk_version: "spdk1",
          use_bdev_ubi: true, skip_sync: true,
          storage_device: storage_device,
          max_read_mbytes_per_sec: 200, max_write_mbytes_per_sec: 300,
          vhost_block_backend_version: "v0.1-5", num_queues: 4, queue_size: 64)
      ]
    }
    let(:total_cpus) { 16 }
    let(:vm_host) { create_vm_host(accepts_slices: true, total_cpus:, total_cores: 8, total_dies: 4, total_sockets: 2) }
    let(:vm) { create_vm(vm_host_id: vm_host.id) }

    before do
      expect(vm).to receive(:vm_storage_volumes).and_return(volumes).at_least(:once)

      SpdkInstallation.create_with_id(vm_host.id, vm_host_id: vm_host.id, version: "v1", allocation_weight: 100, cpu_count: 2)
      (0..total_cpus - 1).each do |cpu|
        VmHostCpu.create(
          vm_host_id: vm_host.id,
          cpu_number: cpu,
          spdk: cpu < vm_host.spdk_cpu_count
        )
      end
    end

    it "returns storage volumes hash list" do
      expect(vm.storage_volumes).to eq([
        {"boot" => true, "image" => "boot_image", "image_version" => "1", "size_gib" => 1,
         "device_id" => "dev1", "disk_index" => 0, "encrypted" => true,
         "spdk_version" => "spdk1", "use_bdev_ubi" => false, "skip_sync" => false,
         "storage_device" => "default", "read_only" => false,
         "max_read_mbytes_per_sec" => nil,
         "max_write_mbytes_per_sec" => nil,
         "vhost_block_backend_version" => nil, "num_queues" => 1, "queue_size" => 256,
         "copy_on_read" => false, "slice_name" => "system.slice"},
        {"boot" => false, "image" => nil, "image_version" => nil, "size_gib" => 100,
         "device_id" => "dev2", "disk_index" => 1, "encrypted" => false,
         "spdk_version" => "spdk1", "use_bdev_ubi" => true, "skip_sync" => true,
         "storage_device" => "default", "read_only" => false,
         "max_read_mbytes_per_sec" => 200,
         "max_write_mbytes_per_sec" => 300,
         "vhost_block_backend_version" => "v0.1-5", "num_queues" => 4, "queue_size" => 64,
         "copy_on_read" => false, "slice_name" => "system.slice"}
      ])
    end

    it "adds the cpus field to the params json when needed" do
      vm_host.update(accepts_slices: false)
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

    let(:vm_host) {
      instance_double(
        VmHost,
        total_cpus: 12,
        total_cores: 12,
        total_dies: 1,
        total_sockets: 1,
        ndp_needed: false,
        ip6_random_vm_network: "fd80:1:2:3::/64"
      )
    }

    it "saves object if there are no exceptions raised" do
      vm.ephemeral_net6 = vm_host.ip6_random_vm_network.to_s
      expect(vm_host).not_to receive(:ip6_random_vm_network)
      vm.save_with_ephemeral_net6_error_retrying(vm_host)
      expect(vm.reload.ephemeral_net6.to_s).to eq "fd80:1:2:3::/64"
    end

    it "retries if there is an Sequel::ValidationFailed exceptions where the only error is for ephemeral_net6" do
      vm2.ephemeral_net6 = vm.ephemeral_net6 = vm_host.ip6_random_vm_network.to_s
      vm2.save_changes
      expect(vm_host).to receive(:ip6_random_vm_network).and_return("fd80:1:2:4::/64")
      vm.save_with_ephemeral_net6_error_retrying(vm_host)
      expect(vm.reload.ephemeral_net6.to_s).to eq "fd80:1:2:4::/64"
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
    before do
      allow(vm).to receive_messages(
        cloud_hypervisor_cpu_topology: Vm::CloudHypervisorCpuTopo.new(1, 1, 1, 1),
        project: instance_double(Project, get_ff_vm_public_ssh_keys: [], get_ff_ipv6_disabled: true),
        nic: instance_double(
          Nic,
          private_subnet: instance_double(
            PrivateSubnet,
            net4: NetAddr::IPv4Net.parse("10.0.0.0/24"),
            random_private_ipv6: NetAddr::IPv6Net.parse("fd00::/64")
          )
        ),
        vm_host: instance_double(VmHost, ndp_needed: false, spdk_installations: [], accepts_slices: true),
        gpu_partition: instance_double(GpuPartition, partition_id: 3)
      )
    end

    it "sets hypervisor to 'qemu' when a B200 GPU (device 2901) is present" do
      allow(vm).to receive(:pci_devices).and_return([instance_double(PciDevice, device: "2901", slot: "0000:00:00.0", iommu_group: "0")])

      json = JSON.parse(vm.params_json)
      expect(json["hypervisor"]).to eq("qemu")
    end

    it "defaults hypervisor to 'ch' when no B200 GPU is present" do
      allow(vm).to receive(:pci_devices).and_return([instance_double(PciDevice, device: "1234", slot: "0000:00:00.0", iommu_group: "0")])

      json = JSON.parse(vm.params_json)
      expect(json["hypervisor"]).to eq("ch")
    end

    it "respects an explicit hypervisor argument even if a B200 GPU is present" do
      allow(vm).to receive(:pci_devices).and_return([instance_double(PciDevice, device: "2901", slot: "0000:00:00.0", iommu_group: "0")])

      json = JSON.parse(vm.params_json(hypervisor: "ch"))
      expect(json["hypervisor"]).to eq("ch")
    end

    it "includes the gpu partition id" do
      allow(vm).to receive(:pci_devices).and_return([instance_double(PciDevice, device: "2901", slot: "0000:00:00.0", iommu_group: "0")])

      json = JSON.parse(vm.params_json)
      expect(json["gpu_partition_id"]).to eq(3)
    end
  end
end
