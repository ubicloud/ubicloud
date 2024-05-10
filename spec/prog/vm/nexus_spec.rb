# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Nexus do
  subject(:nx) {
    described_class.new(st).tap {
      _1.instance_variable_set(:@vm, vm)
    }
  }

  let(:st) { Strand.new }
  let(:vm) {
    kek = StorageKeyEncryptionKey.new(
      algorithm: "aes-256-gcm", key: "key",
      init_vector: "iv", auth_data: "somedata"
    ) { _1.id = "04a3fe32-4cf0-48f7-909e-e35822864413" }
    si = SpdkInstallation.new(version: "v1") { _1.id = SpdkInstallation.generate_uuid }
    bi = BootImage.new(name: "my-image", version: "20230303") { _1.id = "b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1" }
    dev1 = StorageDevice.new(name: "nvme0") { _1.id = StorageDevice.generate_uuid }
    dev2 = StorageDevice.new(name: "DEFAULT") { _1.id = StorageDevice.generate_uuid }
    disk_1 = VmStorageVolume.new(boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false)
    disk_1.spdk_installation = si
    disk_1.key_encryption_key_1 = kek
    disk_1.storage_device = dev1
    disk_2 = VmStorageVolume.new(boot: false, size_gib: 15, disk_index: 1, use_bdev_ubi: true, skip_sync: true)
    disk_2.spdk_installation = si
    disk_2.storage_device = dev2
    disk_2.boot_image = bi
    vm = Vm.new(family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "hetzner-hel1", created_at: Time.now).tap {
      _1.id = "2464de61-7501-8374-9ab0-416caebe31da"
      _1.vm_storage_volumes.append(disk_1)
      _1.vm_storage_volumes.append(disk_2)
      disk_1.vm = _1
      disk_2.vm = _1
      allow(_1).to receive(:active_billing_record).and_return(BillingRecord.new(
        project_id: "50089dcf-b472-8ad2-9ca6-b3e70d12759d",
        resource_name: _1.name,
        billing_rate_id: BillingRate.from_resource_properties("VmCores", _1.family, _1.location)["id"],
        amount: _1.cores
      ))
    }
    vm
  }
  let(:prj) { Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) } }

  describe ".assemble" do
    let(:ps) {
      PrivateSubnet.create(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting") { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
    }
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { _1.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
    }

    it "fails if there is no project" do
      expect {
        described_class.assemble("some_ssh_key", "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing project"
    end

    it "fails if project's provider and location's provider not matched" do
      expect {
        described_class.assemble("some_ssh_key", prj.id, location: "dp-istanbul-mars")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: provider"
    end

    it "creates Subnet and Nic if not passed" do
      expect {
        described_class.assemble("some_ssh_key", prj.id)
      }.to change(PrivateSubnet, :count).from(0).to(1)
        .and change(Nic, :count).from(0).to(1)
    end

    it "creates Nic if only subnet_id is passed" do
      expect(PrivateSubnet).to receive(:[]).with(ps.id).and_return(ps)
      expect(Prog::Vnet::NicNexus).to receive(:assemble).and_return(nic)
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:update).and_return(nic)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj).to receive(:private_subnets).and_return([ps]).at_least(:once)

      described_class.assemble("some_ssh_key", prj.id, private_subnet_id: ps.id)
    end

    it "adds the VM to a private subnet if nic_id is passed" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:private_subnet).and_return(ps).at_least(:once)
      expect(nic).to receive(:update).and_return(nic)
      expect(Prog::Vnet::SubnetNexus).not_to receive(:assemble)
      expect(Prog::Vnet::NicNexus).not_to receive(:assemble)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj.private_subnets).to receive(:any?).and_return(true)
      described_class.assemble("some_ssh_key", prj.id, nic_id: nic.id, location: "hetzner-hel1")
    end

    def requested_disk_size(st)
      st.stack.first["storage_volumes"].first["size_gib"]
    end

    it "creates with default storage size from vm size" do
      st = described_class.assemble("some_ssh_key", prj.id)
      expect(requested_disk_size(st)).to eq(Option::VmSizes.first.storage_size_gib)
    end

    it "creates with custom storage size if provided" do
      st = described_class.assemble("some_ssh_key", prj.id, storage_volumes: [{size_gib: 40}])
      expect(requested_disk_size(st)).to eq(40)
    end

    it "fails if given nic_id is not valid" do
      expect {
        described_class.assemble("some_ssh_key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if given subnet_id is not valid" do
      expect {
        described_class.assemble("some_ssh_key", prj.id, private_subnet_id: nic.id)
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if nic is assigned to a different vm" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:vm_id).and_return("57afa8a7-2357-4012-9632-07fbe13a3133")
      expect {
        described_class.assemble("some_ssh_key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is assigned to a VM already"
    end

    it "fails if nic subnet is in another location" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:location).and_return("hel2")
      expect {
        described_class.assemble("some_ssh_key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is created in a different location"
    end

    it "fails if subnet of nic belongs to another project" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj).to receive(:private_subnets).and_return([ps]).at_least(:once)
      expect(prj.private_subnets).to receive(:any?).and_return(false)
      expect {
        described_class.assemble("some_ssh_key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is not available in the given project"
    end

    it "fails if subnet belongs to another project" do
      expect(PrivateSubnet).to receive(:[]).with(ps.id).and_return(ps)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj).to receive(:private_subnets).and_return([ps]).at_least(:once)
      expect(prj.private_subnets).to receive(:any?).and_return(false)
      expect {
        described_class.assemble("some_ssh_key", prj.id, private_subnet_id: ps.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the given project"
    end

    it "creates arm64 vm with double core count and 3.2GB memory per core" do
      st = described_class.assemble("some_ssh_key", prj.id, size: "standard-4", arch: "arm64")
      expect(st.subject.cores).to eq(4)
      expect(st.subject.mem_gib_ratio).to eq(3.2)
      expect(st.subject.mem_gib).to eq(12)
    end
  end

  describe ".assemble_with_sshable" do
    it "calls .assemble with generated ssh key" do
      st_id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5"
      expect(SshKey).to receive(:generate).and_return(instance_double(SshKey, public_key: "public", keypair: "pair"))
      expect(described_class).to receive(:assemble) do |public_key, project_id, **kwargs|
        expect(public_key).to eq("public")
        expect(project_id).to eq(prj.id)
        expect(kwargs[:name]).to be_nil
        expect(kwargs[:size]).to eq("new_size")
        expect(kwargs[:unix_user]).to eq("test_user")
      end.and_return(Strand.new(id: st_id))
      expect(Sshable).to receive(:create).with({unix_user: "test_user", host: "temp_#{st_id}", raw_private_key_1: "pair"})

      described_class.assemble_with_sshable("test_user", prj.id, size: "new_size")
    end
  end

  describe "#storage_volumes" do
    it "includes all storage volumes" do
      expect(nx.storage_volumes).to eq([
        {"boot" => true, "disk_index" => 0, "image" => nil, "size_gib" => 20, "device_id" => "vm4hjdwr_0", "encrypted" => true,
         "spdk_version" => "v1", "use_bdev_ubi" => false, "skip_sync" => false, "storage_device" => "nvme0", "image_version" => nil},
        {"boot" => false, "disk_index" => 1, "image" => nil, "size_gib" => 15, "device_id" => "vm4hjdwr_1", "encrypted" => false,
         "spdk_version" => "v1", "use_bdev_ubi" => true, "skip_sync" => true, "storage_device" => "DEFAULT", "image_version" => "20230303"}
      ])
    end
  end

  describe "#create_unix_user" do
    it "runs adduser" do
      sshable = instance_double(Sshable)
      vm_host = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vm_host)
      expect(sshable).to receive(:cmd).with(/sudo.*userdel.*#{nx.vm_name}/)
      expect(sshable).to receive(:cmd).with(/sudo.*groupdel.*#{nx.vm_name}/)
      expect(sshable).to receive(:cmd).with(/sudo.*adduser.*#{nx.vm_name}/)

      expect { nx.create_unix_user }.to hop("prep")
    end
  end

  describe "#prep" do
    it "hops to run if prep command is succeeded" do
      sshable = instance_spy(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with(/common\/bin\/daemonizer --clean prep_/)
      nic = Nic.new(private_ipv6: "fd10:9b0b:6b4b:8fbb::/64", private_ipv4: "10.0.0.3/32", mac: "5a:0f:75:80:c3:64")
      expect(vm).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_setup_nic)
      vmh = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vmh)
      expect { nx.prep }.to hop("run")
    end

    it "generates and passes a params json if prep command is not started yet" do
      vm = nx.vm
      vm.ephemeral_net6 = "fe80::/64"
      vm.unix_user = "test_user"
      vm.public_key = "test_ssh_key"
      vm.local_vetho_ip = "169.254.0.0"
      nic = Nic.new(private_ipv6: "fd10:9b0b:6b4b:8fbb::/64", private_ipv4: "10.0.0.3/32", mac: "5a:0f:75:80:c3:64")
      pci = PciDevice.new(slot: "01:00.0", iommu_group: 23)
      expect(nic).to receive(:ubid_to_tap_name).and_return("tap4ncdd56m")
      expect(vm).to receive(:nics).and_return([nic]).at_least(:once)
      expect(vm).to receive(:cloud_hypervisor_cpu_topology).and_return(Vm::CloudHypervisorCpuTopo.new(1, 1, 1, 1))
      expect(vm).to receive(:pci_devices).and_return([pci]).at_least(:once)

      sshable = instance_spy(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("NotStarted")
      vmh = instance_double(VmHost, sshable: sshable,
        total_cpus: 80, total_cores: 80, total_sockets: 1, ndp_needed: false)
      expect(vm).to receive(:vm_host).and_return(vmh)

      expect(sshable).to receive(:cmd).with(/sudo -u vm[0-9a-z]+ tee/, stdin: String) do |**kwargs|
        require "json"
        params = JSON(kwargs.fetch(:stdin))
        expect(params).to include({
          "public_ipv6" => "fe80::/64",
          "unix_user" => "test_user",
          "ssh_public_key" => "test_ssh_key",
          "max_vcpus" => 1,
          "cpu_topology" => "1:1:1:1",
          "mem_gib" => 8,
          "local_ipv4" => "169.254.0.0",
          "nics" => [["fd10:9b0b:6b4b:8fbb::/64", "10.0.0.3/32", "tap4ncdd56m", "5a:0f:75:80:c3:64"]],
          "swap_size_bytes" => nil,
          "pci_devices" => [["01:00.0", 23]]
        })
      end
      expect(sshable).to receive(:cmd).with(/sudo host\/bin\/setup-vm prep #{nx.vm_name}/, {stdin: /{"storage":{"vm.*_0":{"key":"key","init_vector":"iv","algorithm":"aes-256-gcm","auth_data":"somedata"}}}/})

      expect { nx.prep }.to nap(1)
    end

    it "naps if prep command is in progress" do
      sshable = instance_spy(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("InProgress")
      vmh = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vmh)
      expect { nx.prep }.to nap(1)
    end

    it "generates local_ipv4 if not set" do
      expect(nx.local_ipv4).to eq("")
    end

    it "generates local_ipv4 if set" do
      vm = nx.vm
      vm.local_vetho_ip = "169.254.0.0"
      expect(nx.local_ipv4).to eq("169.254.0.0")
    end
  end

  describe "#start" do
    let(:vmh_id) { "46ca6ded-b056-4723-bd91-612959f52f6f" }
    let(:storage_volumes) {
      [{
        "use_bdev_ubi" => false,
        "skip_sync" => true,
        "size_gib" => 11,
        "boot" => true
      }]
    }

    before do
      allow(nx).to receive(:frame).and_return("storage_volumes" => :storage_volumes)
      allow(nx).to receive(:clear_stack_storage_volumes)
      allow(vm).to receive(:update)
    end

    it "creates a page if no capacity left and naps" do
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host")).twice
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
      expect(Page.from_tag_parts("NoCapacity", vm.location, vm.arch)).not_to be_nil

      # Second run does not generate another page
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
    end

    it "resolves the page if no VM left in the queue after 15 minutes" do
      # First run creates the page
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host"))
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)

      # Second run is able to allocate, but there are still vms in the queue, so we don't resolve the page
      expect(Scheduling::Allocator).to receive(:allocate)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be false

      # Third run is able to allocate and there are no vms left in the queue, but it's not 15 minutes yet, so we don't resolve the page
      expect(Scheduling::Allocator).to receive(:allocate)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be false

      # Fourth run is able to allocate and there are no vms left in the queue after 15 minutes, so we resolve the page
      Page.active.first.update(created_at: Time.now - 16 * 60)
      expect(Scheduling::Allocator).to receive(:allocate)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be true
    end

    it "re-raises exceptions other than lack of capacity" do
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("will not allocate because allocating is too mainstream and I'm too cool for that"))
      expect {
        nx.start
      }.to raise_error(RuntimeError, "will not allocate because allocating is too mainstream and I'm too cool for that")
    end

    it "allocates with expected parameters" do
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        location_filter: ["hetzner-hel1"],
        location_preference: [],
        gpu_enabled: false
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "considers all locations for github-runners" do
      vm.location = "github-runners"
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        location_filter: [],
        location_preference: ["github-runners"],
        gpu_enabled: false
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "can force allocating a host" do
      allow(nx).to receive(:frame).and_return({
        "force_host_id" => :vm_host_id,
        "storage_volumes" => :storage_volumes
      })

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: [],
        distinct_storage_devices: false,
        host_filter: [:vm_host_id],
        location_filter: [],
        location_preference: [],
        gpu_enabled: false
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "requests distinct storage devices" do
      allow(nx).to receive(:frame).and_return({
        "distinct_storage_devices" => true,
        "storage_volumes" => :storage_volumes,
        "gpu_enabled" => false
      })

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: true,
        host_filter: [],
        location_filter: ["hetzner-hel1"],
        location_preference: [],
        gpu_enabled: false
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "requests a gpu" do
      allow(nx).to receive(:frame).and_return({
        "gpu_enabled" => true,
        "storage_volumes" => :storage_volumes
      })

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        location_filter: ["hetzner-hel1"],
        location_preference: [],
        gpu_enabled: true
      )
      expect { nx.start }.to hop("create_unix_user")
    end
  end

  describe "#clear_stack_storage_volumes" do
    it "removes storage volume info" do
      strand = instance_double(Strand)
      stack = [{"storage_volumes" => []}]
      allow(nx).to receive(:strand).and_return(strand)
      expect(strand).to receive(:stack).and_return(stack)
      expect(strand).to receive(:modified!).with(:stack)
      expect(strand).to receive(:save_changes)

      expect { nx.clear_stack_storage_volumes }.not_to raise_error
    end
  end

  describe "#run" do
    it "runs the vm" do
      sshable = instance_double(Sshable)
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, sshable: sshable))
      expect(sshable).to receive(:cmd).with(/sudo systemctl start vm/)
      expect { nx.run }.to hop("wait_sshable")
    end
  end

  describe "#wait_sshable" do
    it "naps 15 second if it's the first time we execute wait_sshable" do
      expect(vm).to receive(:update_firewall_rules_set?).and_return(false)
      expect(vm).to receive(:incr_update_firewall_rules)
      expect { nx.wait_sshable }.to nap(15)
    end

    it "naps if not sshable" do
      expect(vm).to receive(:ephemeral_net4).and_return("10.0.0.1")
      expect(vm).to receive(:update_firewall_rules_set?).and_return(true)
      expect(vm).not_to receive(:incr_update_firewall_rules)
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      expect(vm).to receive(:update_firewall_rules_set?).and_return(true)
      expect(vm).not_to receive(:incr_update_firewall_rules)
      vm_addr = instance_double(AssignedVmAddress, id: "46ca6ded-b056-4723-bd91-612959f52f6f", ip: NetAddr::IPv4Net.parse("10.0.0.1"))
      expect(vm).to receive(:assigned_vm_address).and_return(vm_addr).at_least(:once)
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "skips a check if ipv4 is not enabled" do
      expect(vm).to receive(:update_firewall_rules_set?).and_return(true)
      expect(vm.ephemeral_net4).to be_nil
      expect(vm).not_to receive(:ephemeral_net6)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end
  end

  describe "#create_billing_record" do
    before do
      now = Time.now
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      expect(vm).to receive(:update).with(display_state: "running", provisioned_at: now).and_return(true)
      expect(Clog).to receive(:emit).with("vm provisioned")
    end

    it "creates billing records when ip4 is enabled" do
      vm_addr = instance_double(AssignedVmAddress, id: "46ca6ded-b056-4723-bd91-612959f52f6f", ip: NetAddr::IPv4Net.parse("10.0.0.1"))
      expect(vm).to receive(:assigned_vm_address).and_return(vm_addr).at_least(:once)
      expect(vm).to receive(:ip4_enabled).and_return(true)
      expect(BillingRecord).to receive(:create_with_id).twice
      expect(vm).to receive(:projects).and_return([prj]).at_least(:once)
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "creates billing records when ip4 is not enabled" do
      expect(vm).to receive(:ip4_enabled).and_return(false)
      expect(BillingRecord).to receive(:create_with_id)
      expect(vm).to receive(:projects).and_return([prj]).at_least(:once)
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "not create billing records when the project is not billable" do
      expect(vm).to receive(:projects).and_return([prj]).at_least(:once)
      expect(prj).to receive(:billable).and_return(false)
      expect(BillingRecord).not_to receive(:create_with_id)
      expect { nx.create_billing_record }.to hop("wait")
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

    it "stops billing before hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm.active_billing_record).to receive(:finalize)
      assigned_adr = instance_double(AssignedVmAddress)
      expect(vm).to receive(:assigned_vm_address).and_return(assigned_adr)
      expect(assigned_adr).to receive(:active_billing_record).and_return(instance_double(BillingRecord)).at_least(:once)
      expect(assigned_adr.active_billing_record).to receive(:finalize)
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm).to receive(:active_billing_record).and_return(nil)
      expect(vm).to receive(:assigned_vm_address).and_return(nil)
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found for ipv4" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm.active_billing_record).to receive(:finalize)
      assigned_adr = instance_double(AssignedVmAddress)
      expect(vm).to receive(:assigned_vm_address).and_return(assigned_adr)
      expect(assigned_adr).to receive(:active_billing_record).and_return(nil)

      expect { nx.before_run }.to hop("destroy")
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to start_after_host_reboot when needed" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect { nx.wait }.to hop("start_after_host_reboot")
    end

    it "hops to update_spdk_dependency when needed" do
      expect(nx).to receive(:when_update_spdk_dependency_set?).and_yield
      expect { nx.wait }.to hop("update_spdk_dependency")
    end

    it "hops to update_firewall_rules when needed" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect { nx.wait }.to hop("update_firewall_rules")
    end

    it "hops to unavailable based on the vm's available status" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#update_firewall_rules" do
    it "hops to wait_firewall_rules" do
      expect(nx).to receive(:decr_update_firewall_rules)
      expect(nx).to receive(:push).with(Prog::Vnet::UpdateFirewallRules, {}, :update_firewall_rules)
      nx.update_firewall_rules
    end

    it "hops to wait if firewall rules are applied" do
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rule is added"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#update_spdk_dependency" do
    it "hops to wait after doing the work" do
      sshable = instance_double(Sshable)
      vm_host = instance_double(VmHost, sshable: sshable)
      allow(vm).to receive(:vm_host).and_return(vm_host)

      expect(nx).to receive(:decr_update_spdk_dependency)
      expect(nx).to receive(:write_params_json)
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-vm reinstall-systemd-units #{vm.inhost_name}")
      expect { nx.update_spdk_dependency }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to start_after_host_reboot when needed" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect(nx).to receive(:incr_checkup)
      expect { nx.unavailable }.to hop("start_after_host_reboot")
    end

    it "creates a page if vm is unavailable" do
      expect(Prog::PageNexus).to receive(:assemble)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "resolves the page if vm is available" do
      pg = instance_double(Page)
      expect(pg).to receive(:incr_resolve)
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(pg)
      expect { nx.unavailable }.to hop("wait")
    end

    it "does not resolves the page if there is none" do
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(nil)
      expect { nx.unavailable }.to hop("wait")
    end
  end

  describe "#prevent_destroy" do
    it "registers a deadline and naps while preventing" do
      expect(nx).to receive(:register_deadline)
      expect { nx.prevent_destroy }.to nap(30)
    end
  end

  describe "#destroy" do
    before do
      st.stack.first["deadline_at"] = Time.now + 1
    end

    context "when has vm_host" do
      let(:sshable) { instance_double(Sshable) }
      let(:vm_host) { instance_double(VmHost, sshable: sshable) }

      before do
        expect(vm).to receive(:vm_host).and_return(vm_host)
        expect(vm).to receive(:update).with(display_state: "deleting")
        vol = instance_double(VmStorageVolume)
        dev = instance_double(StorageDevice)
        allow(Sequel).to receive(:[]).with(:available_storage_gib).and_return(100)
        allow(Sequel).to receive(:[]).with(:used_cores).and_return(1)
        allow(Sequel).to receive(:[]).with(:used_hugepages_1g).and_return(8)
        allow(vol).to receive(:storage_device_dataset).and_return(dev)
        allow(dev).to receive(:update).with(available_storage_gib: 105)
        allow(vol).to receive_messages(storage_device: dev, size_gib: 5)
        allow(vm).to receive(:vm_storage_volumes).and_return([vol])
      end

      it "absorbs an already deleted errors as a success" do
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}/).and_raise(
          Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
        )
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/).and_raise(
          Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
        )
        expect(sshable).to receive(:cmd).with(/sudo.*bin\/setup-vm delete #{nx.vm_name}/)
        expect(vm).to receive(:destroy).and_return(true)

        expect { nx.destroy }.to exit({"msg" => "vm deleted"})
      end

      it "raises other stop errors" do
        ex = Sshable::SshError.new("stop", "", "unknown error", 1, nil)
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}/).and_raise(ex)

        expect { nx.destroy }.to raise_error ex
      end

      it "raises other stop-dnsmasq errors" do
        ex = Sshable::SshError.new("stop", "", "unknown error", 1, nil)
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}/)
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/).and_raise(ex)
        expect { nx.destroy }.to raise_error ex
      end

      it "deletes and pops when all commands are succeeded" do
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}/)
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/)
        expect(sshable).to receive(:cmd).with(/sudo.*bin\/setup-vm delete #{nx.vm_name}/)

        expect(vm).to receive(:destroy)

        expect { nx.destroy }.to exit({"msg" => "vm deleted"})
      end
    end

    it "prevents destroy if the semaphore set" do
      expect(nx).to receive(:when_prevent_destroy_set?).and_yield
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore")
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "detaches from nic" do
      nic = instance_double(Nic)
      expect(nic).to receive(:update).with(vm_id: nil)
      expect(nic).to receive(:incr_destroy)
      expect(vm).to receive(:nics).and_return([nic])
      expect(vm).to receive(:update).with(display_state: "deleting")
      expect(vm).to receive(:destroy)
      allow(vm).to receive(:vm_storage_volumes).and_return([])

      expect { nx.destroy }.to exit({"msg" => "vm deleted"})
    end

    it "detaches from pci devices" do
      ds = instance_double(Sequel::Dataset)
      expect(vm).to receive(:pci_devices_dataset).and_return(ds)
      expect(ds).to receive(:update).with(vm_id: nil)
      expect(vm).to receive(:update).with(display_state: "deleting")
      expect(vm).to receive(:destroy)
      allow(vm).to receive(:vm_storage_volumes).and_return([])

      expect { nx.destroy }.to exit({"msg" => "vm deleted"})
    end
  end

  describe "#start_after_host_reboot" do
    let(:sshable) { instance_double(Sshable) }
    let(:vm_host) { instance_double(VmHost, sshable: sshable) }

    before do
      expect(vm).to receive(:vm_host).and_return(vm_host)
    end

    it "can start a vm after reboot" do
      expect(sshable).to receive(:cmd).with(
        /sudo host\/bin\/setup-vm recreate-unpersisted #{nx.vm_name}/,
        {stdin: /{"storage":{"vm.*_0":{"key":"key","init_vector":"iv","algorithm":"aes-256-gcm","auth_data":"somedata"}}}/}
      )
      expect(sshable).to receive(:cmd).with(/sudo systemctl start vm[0-9a-z]+/)
      expect(vm).to receive(:update).with(display_state: "starting")
      expect(vm).to receive(:update).with(display_state: "running")
      expect(vm).to receive(:incr_update_firewall_rules)
      expect { nx.start_after_host_reboot }.to hop("wait")
    end
  end

  describe "#available?" do
    it "returns the available status" do
      vh = instance_double(VmHost, sshable: instance_double(Sshable))
      expect(vh.sshable).to receive(:cmd).and_return("active\nactive\n")
      expect(vm).to receive(:vm_host).and_return(vh)
      expect(vm).to receive(:inhost_name).and_return("vmxxxx").at_least(:once)
      expect(nx.available?).to be true
    end
  end
end
