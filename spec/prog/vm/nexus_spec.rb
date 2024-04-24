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
    dev1 = StorageDevice.new(name: "nvme0") { _1.id = StorageDevice.generate_uuid }
    dev2 = StorageDevice.new(name: "DEFAULT") { _1.id = StorageDevice.generate_uuid }
    disk_1 = VmStorageVolume.new(boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false)
    disk_1.spdk_installation = si
    disk_1.key_encryption_key_1 = kek
    disk_1.storage_device = dev1
    disk_2 = VmStorageVolume.new(boot: false, size_gib: 15, disk_index: 1, use_bdev_ubi: true, skip_sync: true)
    disk_2.spdk_installation = si
    disk_2.storage_device = dev2
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
  let(:prj) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

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
         "spdk_version" => "v1", "use_bdev_ubi" => false, "skip_sync" => false, "storage_device" => "nvme0"},
        {"boot" => false, "disk_index" => 1, "image" => nil, "size_gib" => 15, "device_id" => "vm4hjdwr_1", "encrypted" => false,
         "spdk_version" => "v1", "use_bdev_ubi" => true, "skip_sync" => true, "storage_device" => "DEFAULT"}
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
      expect(nic).to receive(:ubid_to_tap_name).and_return("tap4ncdd56m")
      expect(vm).to receive(:nics).and_return([nic]).at_least(:once)
      expect(vm).to receive(:cloud_hypervisor_cpu_topology).and_return(Vm::CloudHypervisorCpuTopo.new(1, 1, 1, 1))

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
          "swap_size_bytes" => nil
        })
      end
      expect(sshable).to receive(:cmd).with(/sudo host\/bin\/prepvm/, {stdin: /{"storage":{"vm.*_0":{"key":"key","init_vector":"iv","algorithm":"aes-256-gcm","auth_data":"somedata"}}}/})

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
    let(:vmh) {
      VmHost.new(
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
        ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2")
      ) { _1.id = vmh_id }
    }

    before do
      allow(nx).to receive(:allocate).and_return(vmh_id)
      allow(VmHost).to receive(:[]).with(vmh_id) { vmh }
      allow(nx).to receive(:create_storage_volume_records)
      allow(nx).to receive(:clear_stack_storage_volumes)
      allow(vm).to receive(:update)
    end

    it "allocates the vm to a host with IPv4 address" do
      address = Address.new(cidr: "0.0.0.0/30", routed_to_host_id: vmh_id)
      assigned_address = AssignedVmAddress.new(ip: NetAddr::IPv4Net.parse("10.0.0.1"))

      expect(nx).to receive(:allocate).and_return(vmh_id)
      expect(nx).to receive(:allocate_storage_devices).and_return([])
      expect(vmh).to receive(:ip4_random_vm_network).and_return(["0.0.0.0", address])
      expect(vm).to receive(:ip4_enabled).and_return(true).twice
      expect(AssignedVmAddress).to receive(:create_with_id).and_return(assigned_address)
      expect(vm).to receive(:assigned_vm_address).and_return(assigned_address)
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable)).at_least(:once)
      expect(vm.sshable).to receive(:update).with(host: assigned_address.ip.network)

      expect { nx.start }.to hop("create_unix_user")
    end

    it "fails if there is no ip address available but the vm is ip4 enabled" do
      expect(vmh).to receive(:ip4_random_vm_network).and_return([nil, nil])
      expect(vm).to receive(:ip4_enabled).and_return(true).at_least(:once)
      expect(nx).to receive(:allocate_storage_devices).and_return([])
      expect { nx.start }.to raise_error(RuntimeError, /no ip4 addresses left/)
    end

    it "creates a page if no capacity left and naps" do
      expect(nx).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible hosts")).twice
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
      expect(Page.from_tag_parts("NoCapacity", vm.location, vm.arch)).not_to be_nil

      # Second run does not generate another page
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
    end

    it "resolves the page if no VM left in the queue after 15 minutes" do
      # First run creates the page
      expect(nx).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible hosts"))
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)

      # Second run is able to allocate, but there are still vms in the queue, so we don't resolve the page
      expect(nx).to receive(:allocate).and_return(vmh_id).twice
      allow(Vm).to receive_message_chain(:join, :where).and_return([vm, vm], [vm]) # rubocop:disable RSpec/MessageChain
      expect(nx).to receive(:allocate_storage_devices).and_return([]).at_least(:once)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be false

      # Third run is able to allocate and there are no vms left in the queue, but it's not 15 minutes yet, so we don't resolve the page
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be false

      # Fourth run is able to allocate and there are no vms left in the queue after 15 minutes, so we resolve the page
      Page.active.first.update(created_at: Time.now - 16 * 60)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be true
    end

    it "re-raises exceptions other than lack of capacity" do
      expect(nx).to receive(:allocate).and_raise(RuntimeError.new("will not allocate because allocating is too mainstream and I'm too cool for that"))
      expect {
        nx.start
      }.to raise_error(RuntimeError, "will not allocate because allocating is too mainstream and I'm too cool for that")
    end
  end

  describe "#allocate" do
    before do
      @host_index = 0
      vm.location = "somewhere-normal"
      allow(nx).to receive(:frame).and_return({
        "storage_volumes" => [{
          "use_bdev_ubi" => false,
          "skip_sync" => true,
          "size_gib" => 11,
          "boot" => true
        }]
      })
    end

    def new_host(**args)
      args = {allocation_state: "accepting",
              location: "somewhere-normal",
              total_sockets: 1,
              total_cores: 80,
              total_cpus: 80,
              total_mem_gib: 640,
              total_hugepages_1g: 640 - 8,
              total_storage_gib: 500,
              available_storage_gib: 200,
              arch: "x64"}.merge(args)
      sa = Sshable.create_with_id(host: "127.0.0.#{@host_index}")
      @host_index += 1

      host = VmHost.create(**args.except(:available_storage_gib, :total_storage_gib)) { _1.id = sa.id }
      StorageDevice.create_with_id(
        name: "DEFAULT",
        available_storage_gib: args[:available_storage_gib],
        total_storage_gib: args[:total_storage_gib],
        vm_host_id: host.id
      )
      SpdkInstallation.create(
        version: "v29.01",
        allocation_weight: 100,
        vm_host_id: host.id
      ) { _1.id = SpdkInstallation.generate_uuid }
      host
    end

    it "fails if there was a concurrent modification to allocation_state" do
      vmh = new_host(allocation_state: "draining")
      ds = instance_double(Sequel::Dataset)

      expect(ds).to receive(:limit).with(1).and_return(ds)
      expect(ds).to receive(:get).with(:id).and_return(vmh.id)
      expect(nx).to receive(:allocation_dataset).and_return(ds)

      expect {
        nx.allocate
      }.to raise_error(RuntimeError, "concurrent allocation_state modification requires re-allocation")
    end

    it "fails if requested distinct storage devices, but only 1 device exists" do
      new_host
      allow(nx).to receive(:frame).and_return({
        "storage_volumes" => [{"size_gib" => 5}, {"size_gib" => 10}],
        "distinct_storage_devices" => true
      })
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"
    end

    it "fails if there are no VmHosts" do
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"
    end

    it "only matches when location matches" do
      vm.location = "somewhere-normal"
      vmh = new_host(location: "somewhere-weird")
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"

      vm.location = "somewhere-weird"
      expect(nx.allocate).to eq vmh.id
      expect(vmh.reload.used_cores).to eq(1)
    end

    it "matches all locations for github-runners" do
      vm.location = "github-runners"
      vmh = new_host(location: "somewhere-weird")
      expect(nx.allocate).to eq vmh.id
    end

    it "prioritizes the github-runners location for runners" do
      new_host(location: "somewhere-weird")
      new_host(location: "somewhere-weird")
      new_host(location: "somewhere-weird")
      vmh = new_host(location: "github-runners")
      new_host(location: "somewhere-weird")
      new_host(location: "somewhere-weird")
      new_host(location: "somewhere-weird")
      vm.location = "github-runners"
      expect(nx.allocate).to eq vmh.id
    end

    it "does not match if there is not enough storage capacity" do
      new_host(available_storage_gib: 10)
      expect(vm.storage_size_gib).to eq(35)
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"
    end

    it "can use all cores" do
      vmh = new_host(used_cores: 79)
      expect(nx.allocate).to eq vmh.id
    end

    it "fails if all cores have been used" do
      new_host(used_cores: 80)
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"
    end

    it "can use all hugepages" do
      vmh = new_host(used_hugepages_1g: 632 - vm.mem_gib)
      expect(nx.allocate).to eq vmh.id
    end

    it "fails if all hugepages have been used" do
      new_host(used_hugepages_1g: 632 - vm.mem_gib + 1)
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"
    end

    it "updates allocated resource columns" do
      vmh = new_host(location: "hetzner-hel1")
      st = described_class.assemble("some_ssh_key", prj.id, storage_volumes: [{size_gib: 10}, {size_gib: 15}])
      nx = described_class.new(st)

      initial_vmh = vmh.dup
      expect(nx.allocate).to eq vmh.reload.id
      expect(vmh.used_cores).to eq(initial_vmh.used_cores + 1)
      expect(vmh.used_hugepages_1g).to eq(initial_vmh.used_hugepages_1g + 8)
    end

    it "can force allocating a host" do
      new_host(location: "hetzner-hel1")
      vmh2 = new_host(location: "hetzner-hel1")
      new_host(location: "hetzner-hel1")

      st = described_class.assemble("some_ssh_key", prj.id, force_host_id: vmh2.id)
      nx = described_class.new(st)

      expect(nx.allocate).to eq vmh2.id
    end

    it "doesn't allocate draining hosts normally" do
      new_host(allocation_state: "draining")
      expect { nx.allocate }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible hosts for somewhere-normal"
    end

    it "can force allocating a draining host" do
      vmh = new_host(allocation_state: "draining")

      st = described_class.assemble("some_ssh_key", prj.id, force_host_id: vmh.id)
      nx = described_class.new(st)

      expect(nx.allocate).to eq vmh.id
    end
  end

  describe "#allocate_storage_devices" do
    let(:vmh) {
      id = VmHost.generate_uuid
      Sshable.create { _1.id = id }
      host = VmHost.create(location: "xyz") { _1.id = id }
      SpdkInstallation.create(vm_host_id: id, version: "v1", allocation_weight: 100) { _1.id = id }
      StorageDevice.create(
        vm_host_id: host.id, name: "nvme0",
        available_storage_gib: 100, total_storage_gib: 150
      ) { _1.id = StorageDevice.generate_uuid }
      StorageDevice.create(
        vm_host_id: host.id, name: "DEFAULT",
        available_storage_gib: 100, total_storage_gib: 100
      ) { _1.id = host.id }
      host
    }

    it "can allocate storage on the same device" do
      storage_volumes = [{"size_gib" => 5}, {"size_gib" => 10}]
      allow(nx).to receive(:frame).and_return({
        "distinct_storage_devices" => false
      })

      volumes = nx.allocate_storage_devices(vmh, storage_volumes)
      expect(volumes[0]["storage_device_id"]).not_to be_nil
      expect(volumes[0]["storage_device_id"]).to eq(volumes[1]["storage_device_id"])
    end

    it "can allocate storage on distinct devices" do
      storage_volumes = [{"size_gib" => 5}, {"size_gib" => 10}]
      allow(nx).to receive(:frame).and_return({
        "distinct_storage_devices" => true
      })

      volumes = nx.allocate_storage_devices(vmh, storage_volumes)
      expect(volumes[0]["storage_device_id"]).not_to be_nil
      expect(volumes[1]["storage_device_id"]).not_to be_nil
      expect(volumes[0]["storage_device_id"]).not_to eq(volumes[1]["storage_device_id"])
    end

    it "fails if not enough space left" do
      storage_volumes = [{"size_gib" => 65}, {"size_gib" => 160}]
      allow(nx).to receive(:frame).and_return({
        "distinct_storage_devices" => false
      })

      expect {
        nx.allocate_storage_devices(vmh, storage_volumes)
      }.to raise_error RuntimeError, "Storage device allocation failed"
    end

    it "skips the first device if it is too small" do
      storage_volumes = [{"size_gib" => 51}, {"size_gib" => 30}]
      allow(nx).to receive(:frame).and_return({
        "distinct_storage_devices" => false
      })

      volumes = nx.allocate_storage_devices(vmh, storage_volumes)
      expect(volumes[0]["storage_device_id"]).not_to be_nil
      expect(volumes[0]["storage_device_id"]).to eq(volumes[1]["storage_device_id"])
    end
  end

  describe "#create_storage_volume_records" do
    let(:vmh) {
      id = VmHost.generate_uuid
      Sshable.create { _1.id = id }
      host = VmHost.create(location: "xyz") { _1.id = id }
      SpdkInstallation.create(vm_host_id: id, version: "v1", allocation_weight: 100) { _1.id = id }
      host
    }

    let(:storage_device) {
      StorageDevice.create(vm_host_id: vmh.id, name: "nvme0", available_storage_gib: 100, total_storage_gib: 100) { _1.id = vmh.id }
    }

    it "creates without encryption key if storage is not encrypted" do
      st = described_class.assemble("some_ssh_key", prj.id)
      nx = described_class.new(st)
      volumes = [{
        "size_gib" => 5,
        "use_bdev_ubi" => false,
        "skip_sync" => false,
        "encrypted" => false,
        "boot" => false,
        "storage_device_id" => storage_device.id
      }]
      nx.create_storage_volume_records(vmh, volumes)
      expect(StorageKeyEncryptionKey.count).to eq(0)
      expect(st.subject.vm_storage_volumes.first.key_encryption_key_1_id).to be_nil
      expect(nx.storage_secrets.count).to eq(0)
    end

    it "creates with encryption key if storage is encrypted" do
      st = described_class.assemble("some_ssh_key", prj.id)
      nx = described_class.new(st)
      volumes = [{
        "size_gib" => 5,
        "use_bdev_ubi" => false,
        "skip_sync" => false,
        "encrypted" => true,
        "boot" => false,
        "storage_device_id" => storage_device.id
      }]
      nx.create_storage_volume_records(vmh, volumes)
      expect(StorageKeyEncryptionKey.count).to eq(1)
      expect(st.subject.vm_storage_volumes.first.key_encryption_key_1_id).not_to be_nil
      expect(nx.storage_secrets.count).to eq(1)
    end
  end

  describe "#allocate_spdk_installation" do
    it "fails if total weight is zero" do
      si_1 = SpdkInstallation.new(allocation_weight: 0)
      si_2 = SpdkInstallation.new(allocation_weight: 0)

      expect { nx.allocate_spdk_installation([si_1, si_2]) }.to raise_error "Total weight of all eligible spdk_installations shouldn't be zero."
    end

    it "chooses the only one if one provided" do
      si_1 = SpdkInstallation.new(allocation_weight: 100) { _1.id = SpdkInstallation.generate_uuid }
      expect(nx.allocate_spdk_installation([si_1])).to eq(si_1.id)
    end

    it "doesn't return the one with zero weight" do
      si_1 = SpdkInstallation.new(allocation_weight: 0) { _1.id = SpdkInstallation.generate_uuid }
      si_2 = SpdkInstallation.new(allocation_weight: 100) { _1.id = SpdkInstallation.generate_uuid }
      expect(nx.allocate_spdk_installation([si_1, si_2])).to eq(si_2.id)
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

  describe "#unavailable" do
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
        expect(sshable).to receive(:cmd).with(/sudo.*bin\/deletevm.rb.*#{nx.vm_name}/)
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
        expect(sshable).to receive(:cmd).with(/sudo.*bin\/deletevm.rb.*#{nx.vm_name}/)

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
  end

  describe "#start_after_host_reboot" do
    let(:sshable) { instance_double(Sshable) }
    let(:vm_host) { instance_double(VmHost, sshable: sshable) }

    before do
      expect(vm).to receive(:vm_host).and_return(vm_host)
    end

    it "can start a vm after reboot" do
      expect(sshable).to receive(:cmd).with(
        /sudo host\/bin\/recreate-unpersisted \/vm\/vm[0-9a-z]+\/prep.json/,
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
