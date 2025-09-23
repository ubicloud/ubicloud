# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Nexus do
  subject(:nx) {
    described_class.new(st).tap {
      it.instance_variable_set(:@vm, vm)
    }
  }

  let(:st) { Strand.new }
  let(:vm) {
    kek = StorageKeyEncryptionKey.new(
      algorithm: "aes-256-gcm", key: "key",
      init_vector: "iv", auth_data: "somedata"
    ) { it.id = "04a3fe32-4cf0-48f7-909e-e35822864413" }
    si = SpdkInstallation.new(version: "v1") { it.id = SpdkInstallation.generate_uuid }
    bi = BootImage.new(name: "my-image", version: "20230303") { it.id = "b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1" }
    dev1 = StorageDevice.new(name: "nvme0") { it.id = StorageDevice.generate_uuid }
    dev2 = StorageDevice.new(name: "DEFAULT") { it.id = StorageDevice.generate_uuid }
    disk_1 = VmStorageVolume.new(boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false)
    disk_1.spdk_installation = si
    disk_1.key_encryption_key_1 = kek
    disk_1.storage_device = dev1
    disk_2 = VmStorageVolume.new(boot: false, size_gib: 15, disk_index: 1, use_bdev_ubi: true, skip_sync: true)
    disk_2.spdk_installation = si
    disk_2.storage_device = dev2
    disk_2.boot_image = bi
    vm = Vm.new(
      name: "dummy-vm",
      unix_user: "ubi",
      public_key: "ssh key",
      boot_image: "ubuntu-jammy",
      family: "standard",
      cores: 1,
      vcpus: 2,
      cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0,
      memory_gib: 8,
      arch: "x64",
      location_id: Location::HETZNER_FSN1_ID,
      created_at: Time.now
    ).tap {
      it.id = "2464de61-7501-8374-9ab0-416caebe31da"
      it.vm_storage_volumes.append(disk_1)
      it.vm_storage_volumes.append(disk_2)
      disk_1.vm = it
      disk_2.vm = it
      allow(it).to receive(:active_billing_records).and_return([BillingRecord.new(
        project_id: "50089dcf-b472-8ad2-9ca6-b3e70d12759d",
        resource_name: it.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", it.family, "hetzner-fsn1")["id"],
        amount: it.vcpus
      )])
    }
    vm
  }
  let(:prj) { Project.create(name: "default") }

  describe ".assemble" do
    let(:ps) {
      PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting", project_id: prj.id) { it.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
    }
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { it.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
    }

    it "fails if there is no project" do
      expect {
        described_class.assemble("some_ssh key", "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing project"
    end

    it "fails if location doesn't exist" do
      expect {
        described_class.assemble("some_ssh key", prj.id, location_id: nil)
      }.to raise_error RuntimeError, "No existing location"
    end

    it "creates Subnet and Nic if not passed" do
      expect {
        described_class.assemble("some_ssh key", prj.id)
      }.to change(PrivateSubnet, :count).from(0).to(1)
        .and change(Nic, :count).from(0).to(1)
    end

    it "creates Nic if only subnet_id is passed" do
      expect(PrivateSubnet).to receive(:[]).with(ps.id).and_return(ps)
      nic_strand = instance_double(Strand, subject: nic)
      expect(Prog::Vnet::NicNexus).to receive(:assemble).and_return(nic_strand)
      expect(nic).to receive(:update).and_return(nic)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj).to receive(:private_subnets).and_return([ps]).at_least(:once)

      described_class.assemble("some_ssh key", prj.id, private_subnet_id: ps.id)
    end

    it "adds the VM to a private subnet if nic_id is passed" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:private_subnet).and_return(ps).at_least(:once)
      expect(nic).to receive(:update).and_return(nic)
      expect(Prog::Vnet::SubnetNexus).not_to receive(:assemble)
      expect(Prog::Vnet::NicNexus).not_to receive(:assemble)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj.private_subnets).to receive(:any?).and_return(true)
      described_class.assemble("some_ssh key", prj.id, nic_id: nic.id, location_id: Location::HETZNER_FSN1_ID)
    end

    def requested_disk_size(st)
      st.stack.first["storage_volumes"].first["size_gib"]
    end

    it "creates with default storage size from vm size" do
      st = described_class.assemble("some_ssh key", prj.id)
      expect(requested_disk_size(st)).to eq(Option::VmSizes.first.storage_size_options.first)
    end

    it "creates with custom storage size if provided" do
      st = described_class.assemble("some_ssh key", prj.id, storage_volumes: [{size_gib: 40}])
      expect(requested_disk_size(st)).to eq(40)
    end

    it "fails if given nic_id is not valid" do
      expect {
        described_class.assemble("some_ssh key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if given subnet_id is not valid" do
      expect {
        described_class.assemble("some_ssh key", prj.id, private_subnet_id: nic.id)
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if nic is assigned to a different vm" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:vm_id).and_return("57afa8a7-2357-4012-9632-07fbe13a3133")
      expect {
        described_class.assemble("some_ssh key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is assigned to a VM already"
    end

    it "fails if nic subnet is in another location" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:location_id).and_return("hel2")
      expect {
        described_class.assemble("some_ssh key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is created in a different location"
    end

    it "fails if subnet of nic belongs to another project" do
      expect(Nic).to receive(:[]).with(nic.id).and_return(nic)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj).to receive(:private_subnets).and_return([ps]).at_least(:once)
      expect(prj.private_subnets).to receive(:any?).and_return(false)
      expect {
        described_class.assemble("some_ssh key", prj.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is not available in the given project"
    end

    it "fails if subnet belongs to another project" do
      expect(PrivateSubnet).to receive(:[]).with(ps.id).and_return(ps)
      expect(Project).to receive(:[]).with(prj.id).and_return(prj)
      expect(prj).to receive(:private_subnets).and_return([ps]).at_least(:once)
      expect(prj.private_subnets).to receive(:any?).and_return(false)
      expect {
        described_class.assemble("some_ssh key", prj.id, private_subnet_id: ps.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the given project"
    end

    it "creates arm64 vm with double core count and 3.2GB memory per core" do
      st = described_class.assemble("some_ssh key", prj.id, size: "standard-4", arch: "arm64")
      expect(st.subject.vcpus).to eq(4)
      expect(st.subject.memory_gib).to eq(12)
    end

    it "requests as many gpus as specified" do
      st = described_class.assemble("some_ssh key", prj.id, size: "standard-2", gpu_count: 2)
      expect(st.stack[0]["gpu_count"]).to eq(2)
    end

    it "requests at least a single gpu for standard-gpu-6" do
      st = described_class.assemble("some_ssh key", prj.id, size: "standard-gpu-6")
      expect(st.stack[0]["gpu_count"]).to eq(1)
    end

    it "requests no gpus by default" do
      st = described_class.assemble("some_ssh key", prj.id, size: "standard-2")
      expect(st.stack[0]["gpu_count"]).to eq(0)
    end

    it "creates correct number of storage volumes for storage optimized instance types" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      storage_volumes = [
        {encrypted: true, size_gib: 30},
        {encrypted: true, size_gib: 7500}
      ]

      vm = described_class.assemble("some_ssh key", prj.id, location_id: loc.id, size: "i8g.8xlarge", arch: "arm64", storage_volumes:).subject
      expect(vm.vm_storage_volumes.count).to eq(3)
    end

    it "hops to start_aws if location is aws" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      st = described_class.assemble("some_ssh key", prj.id, location_id: loc.id)
      expect(st.label).to eq("start_aws")
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
      end.and_return(Strand.new(id: st_id))
      expect(Sshable).to receive(:create_with_id).with(st_id, host: "temp_#{st_id}", raw_private_key_1: "pair", unix_user: "rhizome")

      described_class.assemble_with_sshable(prj.id, size: "new_size")
    end
  end

  describe "#start_aws" do
    it "naps if vm nics are not in wait state" do
      expect(nx).to receive(:vm).and_return(instance_double(Vm, nics: [instance_double(Nic, strand: instance_double(Strand, label: "start"))]))
      expect { nx.start_aws }.to nap(5)
    end

    it "hops to wait_aws_vm_started if vm nics are in wait state" do
      expect(nx).to receive(:vm).and_return(instance_double(Vm, id: "vm_id", nics: [instance_double(Nic, strand: instance_double(Strand, label: "wait"))])).at_least(:once)
      expect(nx).to receive(:bud).with(Prog::Aws::Instance, {"subject_id" => "vm_id"}, :start)
      expect { nx.start_aws }.to hop("wait_aws_vm_started")
    end
  end

  describe "#wait_aws_vm_started" do
    it "reaps and naps if not leaf" do
      st.update(prog: "Vm::Nexus", label: "wait_aws_vm_started", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Instance", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_aws_vm_started }.to nap(10)
    end

    it "hops to wait_sshable if leaf" do
      st.update(prog: "Vm::Nexus", label: "wait_aws_vm_started", stack: [{}])
      expect { nx.wait_aws_vm_started }.to hop("wait_sshable")
    end
  end

  describe "#create_unix_user" do
    it "runs adduser" do
      sshable = instance_double(Sshable)
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, sshable: sshable))
      expect(nx).to receive(:rand).and_return(1111)
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        # Make this script idempotent
        sudo userdel --remove --force #{nx.vm_name} || true
        sudo groupdel -f #{nx.vm_name} || true
        # Create vm's user and home directory
        sudo adduser --disabled-password --gecos '' --home #{nx.vm_home} --uid 1111 #{nx.vm_name}
        # Enable KVM access for VM user
        sudo usermod -a -G kvm #{nx.vm_name}
      COMMAND

      expect { nx.create_unix_user }.to hop("prep")
    end
  end

  describe "#prep" do
    it "hops to run if prep command is succeeded" do
      sshable = instance_spy(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("Succeeded")
      vmh = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vmh)
      expect { nx.prep }.to hop("clean_prep")
    end

    [
      {"swap_size_bytes" => nil},
      {"swap_size_bytes" => nil, "hugepages" => false, "ch_version" => "46.0", "firmware_version" => "202311"}
    ].each do |frame_update|
      it "generates and passes a params json if prep command is not started yet (with frame opts: #{frame_update.inspect})" do
        nx.strand.stack.first.update(frame_update)
        nx.instance_variable_set(:@frame, nil)
        vm = nx.vm
        vm.ephemeral_net6 = "fe80::/64"
        vm.unix_user = "test_user"
        vm.public_key = "test_ssh_key"
        vm.local_vetho_ip = "169.254.0.0"
        ps = instance_double(PrivateSubnet, location_id: Location::HETZNER_FSN1_ID, net4: NetAddr::IPv4Net.parse("10.0.0.0/26"), random_private_ipv6: "fd10:9b0b:6b4b:8fbb::/64")
        nic = Nic.new(private_ipv6: "fd10:9b0b:6b4b:8fbb::/64", private_ipv4: "10.0.0.3/32", mac: "5a:0f:75:80:c3:64")
        pci = PciDevice.new(slot: "01:00.0", iommu_group: 23)
        expect(nic).to receive(:ubid_to_tap_name).and_return("tap4ncdd56m")
        expect(vm).to receive(:nics).and_return([nic]).at_least(:once)
        expect(nic).to receive(:private_subnet).and_return(ps).at_least(:once)
        expect(vm).to receive(:cloud_hypervisor_cpu_topology).and_return(Vm::CloudHypervisorCpuTopo.new(2, 1, 1, 1))
        expect(vm).to receive(:pci_devices).and_return([pci]).at_least(:once)

        prj.set_ff_vm_public_ssh_keys(["operator_ssh_key"])
        expect(prj).to receive(:get_ff_ipv6_disabled).and_return(true).at_least(:once)
        expect(vm).to receive(:project).and_return(prj).at_least(:once)

        sshable = instance_double(Sshable)
        expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("NotStarted")
        vmh = instance_double(VmHost, sshable: sshable,
          total_cpus: 80, total_cores: 80, total_sockets: 10, ndp_needed: false, arch: "arm64")
        expect(vm).to receive(:vm_host).and_return(vmh).at_least(:once)
        expect(sshable).to receive(:cmd).with(/sudo -u vm[0-9a-z]+ tee/, stdin: String) do |**kwargs|
          require "json"
          params = JSON(kwargs.fetch(:stdin))
          expect(params).to include(
            "public_ipv6" => "fd10:9b0b:6b4b:8fbb::/64",
            "unix_user" => "test_user",
            "ssh_public_keys" => ["test_ssh_key", "operator_ssh_key"],
            "ipv6_disabled" => true,
            "max_vcpus" => 2,
            "cpu_topology" => "2:1:1:1",
            "mem_gib" => 8,
            "local_ipv4" => "169.254.0.0",
            "nics" => [["fd10:9b0b:6b4b:8fbb::/64", "10.0.0.3/32", "tap4ncdd56m", "5a:0f:75:80:c3:64", "10.0.0.1/26"]],
            "swap_size_bytes" => nil,
            "pci_devices" => [["01:00.0", 23]],
            "slice_name" => "system.slice",
            "cpu_percent_limit" => 200,
            "cpu_burst_percent_limit" => 0,
            **frame_update
          )
        end
        expect(sshable).to receive(:cmd).with(/sudo host\/bin\/setup-vm prep #{nx.vm_name}/, {stdin: /{"storage":{"vm.*_0":{"key":"key","init_vector":"iv","algorithm":"aes-256-gcm","auth_data":"somedata"}}}/})

        expect { nx.prep }.to nap(1)
      end
    end

    it "naps if prep command is in progress" do
      sshable = instance_spy(Sshable)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("InProgress")
      vmh = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vmh)
      expect { nx.prep }.to nap(1)
    end
  end

  describe "#clean_prep" do
    it "cleans and hops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with(/common\/bin\/daemonizer --clean prep_/)
      vmh = instance_double(VmHost, sshable: sshable)
      expect(vm).to receive(:vm_host).and_return(vmh)
      expect { nx.clean_prep }.to hop("wait_sshable")
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
      expect(vm).to receive(:waiting_for_capacity_set?).and_return(false)
      expect(nx).to receive(:incr_waiting_for_capacity)
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
      expect(Page.from_tag_parts("NoCapacity", Location[vm.location_id].display_name, vm.arch, vm.family)).not_to be_nil

      # Second run does not generate another page
      expect(vm).to receive(:waiting_for_capacity_set?).and_return(true)
      expect(nx).not_to receive(:incr_waiting_for_capacity)
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
    end

    it "waits for a while before creating a page for github-runners" do
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host"))
      expect(vm).to receive(:waiting_for_capacity_set?).and_return(false)
      expect(nx).to receive(:incr_waiting_for_capacity)

      vm.created_at = Time.now - 10 * 60
      vm.location_id = Location[name: "github-runners"].id
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(0)
    end

    it "resolves the page if no VM left in the queue after 15 minutes" do
      # First run creates the page
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host"))
      expect(vm).to receive(:waiting_for_capacity_set?).and_return(false)
      expect(nx).to receive(:incr_waiting_for_capacity)
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)

      # Second run is able to allocate, but there are still vms in the queue, so we don't resolve the page
      expect(Scheduling::Allocator).to receive(:allocate)
      expect(nx).to receive(:decr_waiting_for_capacity)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be false

      # Third run is able to allocate and there are no vms left in the queue, but it's not 15 minutes yet, so we don't resolve the page
      expect(Scheduling::Allocator).to receive(:allocate)
      expect(nx).to receive(:decr_waiting_for_capacity)
      expect { nx.start }.to hop("create_unix_user")
      expect(Page.active.count).to eq(1)
      expect(Page.active.first.resolve_set?).to be false

      # Fourth run is able to allocate and there are no vms left in the queue after 15 minutes, so we resolve the page
      Page.active.first.update(created_at: Time.now - 16 * 60)
      expect(Scheduling::Allocator).to receive(:allocate)
      expect(nx).to receive(:decr_waiting_for_capacity)
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
        host_exclusion_filter: [],
        location_filter: [Location::HETZNER_FSN1_ID],
        location_preference: [],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "considers EU locations for github-runners" do
      vm.location_id = Location::GITHUB_RUNNERS_ID
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "considers standard family for burstable virtual machines" do
      vm.family = "burstable"
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::HETZNER_FSN1_ID],
        location_preference: [],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "considers filtered locations for runners if set for the installation" do
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: prj.id, created_at: Time.now - 8 * 24 * 60 * 60, allocator_preferences: {"location_filter" => [Location::GITHUB_RUNNERS_ID, Location::LEASEWEB_WDC02_ID]})
      GithubRunner.create(vm_id: vm.id, repository_name: "ubicloud/test", label: "ubicloud", installation_id: installation.id)
      vm.location_id = Location::GITHUB_RUNNERS_ID

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::LEASEWEB_WDC02_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "considers preferred locations for runners if set for the installation" do
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: prj.id, created_at: Time.now - 8 * 24 * 60 * 60, allocator_preferences: {
        "location_filter" => [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID, Location::LEASEWEB_WDC02_ID],
        "location_preference" => [Location::LEASEWEB_WDC02_ID]
      })
      GithubRunner.create(vm_id: vm.id, repository_name: "ubicloud/test", label: "ubicloud", installation_id: installation.id)
      vm.location_id = Location::GITHUB_RUNNERS_ID

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID, Location::LEASEWEB_WDC02_ID],
        location_preference: [Location::LEASEWEB_WDC02_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "considers preferred families for runners if set for the installation" do
      vm.location_id = Location::GITHUB_RUNNERS_ID
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: prj.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      GithubRunner.create(label: "ubicloud", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard", "premium"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "allows premium family allocation if free runner upgrade runner is enabled" do
      vm.location_id = Location::GITHUB_RUNNERS_ID
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: prj.id)
      GithubRunner.create(label: "ubicloud", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
      prj.set_ff_free_runner_upgrade_until(Time.now + 5 * 24 * 60 * 60)
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard", "premium"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "do not downgrade the premium runner if it's explicitly requested" do
      vm.location_id = Location::GITHUB_RUNNERS_ID
      vm.family = "premium"
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: prj.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      GithubRunner.create(label: "ubicloud-premium-30", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["premium"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "do not upgrade to the premium runner if not allowed" do
      vm.location_id = Location::GITHUB_RUNNERS_ID
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: prj.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      runner = Prog::Vm::GithubRunner.assemble(installation, repository_name: "ubicloud/test", label: "ubicloud-standard-2").subject.update(vm_id: vm.id)
      runner.incr_not_upgrade_premium
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
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
        host_exclusion_filter: [],
        location_filter: [],
        location_preference: [],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: []
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "can exclude hosts" do
      allow(nx).to receive(:frame).and_return({
        "exclude_host_ids" => [:vm_host_id, "another-vm-host-id"],
        "storage_volumes" => :storage_volumes
      })

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [:vm_host_id, "another-vm-host-id"],
        location_filter: [Location::HETZNER_FSN1_ID],
        location_preference: [],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "fails if same host is forced and excluded" do
      expect {
        described_class.assemble("some_ssh key", prj.id,
          force_host_id: "some-vm-host-id", exclude_host_ids: ["some-vm-host-id"])
      }.to raise_error RuntimeError, "Cannot force and exclude the same host"
    end

    it "requests distinct storage devices" do
      allow(nx).to receive(:frame).and_return({
        "distinct_storage_devices" => true,
        "storage_volumes" => :storage_volumes,
        "gpu_count" => 0
      })

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: true,
        host_filter: [],
        location_filter: [Location::HETZNER_FSN1_ID],
        host_exclusion_filter: [],
        location_preference: [],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "requests gpus" do
      allow(nx).to receive(:frame).and_return({
        "gpu_count" => 3,
        "storage_volumes" => :storage_volumes
      })

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, :storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::HETZNER_FSN1_ID],
        location_preference: [],
        gpu_count: 3,
        gpu_device: nil,
        family_filter: ["standard"]
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

  describe "#wait_sshable" do
    it "naps 6 seconds if it's the first time we execute wait_sshable" do
      expect(vm).to receive(:update_firewall_rules_set?).and_return(false)
      expect(vm).to receive(:incr_update_firewall_rules)
      expect { nx.wait_sshable }.to nap(6)
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
      allow(vm).to receive(:allocated_at).and_return(now - 100)
      expect(vm).to receive(:update).with(display_state: "running", provisioned_at: now).and_return(true)
      expect(Clog).to receive(:emit).with("vm provisioned").and_yield
    end

    it "creates billing records when ip4 is enabled" do
      vm_addr = instance_double(AssignedVmAddress, id: "46ca6ded-b056-4723-bd91-612959f52f6f", ip: NetAddr::IPv4Net.parse("10.0.0.1"))
      expect(vm).to receive(:assigned_vm_address).and_return(vm_addr).at_least(:once)
      expect(vm).to receive(:ip4_enabled).and_return(true)
      expect(BillingRecord).to receive(:create).exactly(4).times
      expect(vm).to receive(:project).and_return(prj).at_least(:once)
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "creates billing records when gpu is present" do
      vm.location = Location[name: "latitude-ai"]
      expect(vm).to receive(:pci_devices).and_return([PciDevice.new(slot: "01:00.0", iommu_group: 23, device_class: "0302", vendor: "10de", device: "20b5")]).at_least(:once)
      expect(BillingRecord).to receive(:create).exactly(4).times
      expect(vm).to receive(:project).and_return(prj).at_least(:once)
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "creates billing records when ip4 is not enabled" do
      expect(vm).to receive(:ip4_enabled).and_return(false)
      expect(BillingRecord).to receive(:create).exactly(3).times
      expect(vm).to receive(:project).and_return(prj).at_least(:once)
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "not create billing records when the project is not billable" do
      expect(vm).to receive(:project).and_return(prj).at_least(:once)
      expect(prj).to receive(:billable).and_return(false)
      expect(BillingRecord).not_to receive(:create)
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "doesn't create billing records for storage volumes, ip4 and pci devices if the location provider is aws" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
      vm.location = loc
      expect(vm).to receive(:project).and_return(prj).at_least(:once)
      expect(vm).not_to receive(:ip4_enabled)
      expect(vm).not_to receive(:pci_devices)
      expect(vm).not_to receive(:storage_volumes)
      expect(BillingRecord).to receive(:create).once
      expect { nx.create_billing_record }.to hop("wait")
    end

    it "creates a billing record when host is nil, too" do
      vm.vm_host = nil
      vm.location.provider = "aws"
      expect(BillingRecord).to receive(:create).once
      expect(vm).to receive(:project).and_return(prj).at_least(:once)

      expect { nx.create_billing_record }.to hop("wait")
    end

    it "create a billing record when host is not nil, too" do
      host = VmHost.new.tap { it.id = "46ca6ded-b056-4723-bd91-612959f52f6f" }
      allow(nx).to receive(:host).and_return(host)
      vm.vm_host = host
      vm.location.provider = "aws"
      expect(BillingRecord).to receive(:create).once
      expect(vm).to receive(:project).and_return(prj).at_least(:once)

      expect { nx.create_billing_record }.to hop("wait")
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield.at_least(:once)
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")

      expect(nx.strand).to receive(:label).and_return("destroy_slice")
      expect { nx.before_run }.not_to hop("destroy")

      expect(nx.strand).to receive(:label).and_return("wait_lb_expiry")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "stops billing before hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm.active_billing_records.first).to receive(:finalize)
      assigned_adr = instance_double(AssignedVmAddress)
      expect(vm).to receive(:assigned_vm_address).and_return(assigned_adr)
      expect(assigned_adr).to receive(:active_billing_record).and_return(instance_double(BillingRecord)).at_least(:once)
      expect(assigned_adr.active_billing_record).to receive(:finalize)
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm).to receive(:active_billing_records).and_return([])
      expect(vm).to receive(:assigned_vm_address).and_return(nil)
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found for ipv4" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm.active_billing_records.first).to receive(:finalize)
      assigned_adr = instance_double(AssignedVmAddress)
      expect(vm).to receive(:assigned_vm_address).and_return(assigned_adr)
      expect(assigned_adr).to receive(:active_billing_record).and_return(nil)

      expect { nx.before_run }.to hop("destroy")
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
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

    it "hops to restart when needed" do
      expect(nx).to receive(:when_restart_set?).and_yield
      expect { nx.wait }.to hop("restart")
    end

    it "hops to stopped when needed" do
      expect(nx).to receive(:when_stop_set?).and_yield
      expect { nx.wait }.to hop("stopped")
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
      expect { nx.wait }.to nap(6 * 60 * 60)
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

  describe "#restart" do
    it "hops to wait after restarting the vm" do
      sshable = instance_double(Sshable)
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, sshable: sshable))
      expect(nx).to receive(:decr_restart)
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-vm restart #{vm.inhost_name}")
      expect { nx.restart }.to hop("wait")
    end
  end

  describe "#stopped" do
    it "naps after stopping the vm" do
      sshable = instance_double(Sshable)
      expect(nx).to receive(:when_stop_set?).and_yield
      expect(vm).to receive(:vm_host).and_return(instance_double(VmHost, sshable: sshable))
      expect(sshable).to receive(:cmd).with("sudo systemctl stop #{vm.inhost_name}")
      expect(nx).to receive(:decr_stop)
      expect { nx.stopped }.to nap(60 * 60)
    end

    it "does not stop if already stopped" do
      expect(vm).not_to receive(:vm_host)
      expect(nx).to receive(:decr_stop)
      expect { nx.stopped }.to nap(60 * 60)
    end
  end

  describe "#unavailable" do
    it "hops to start_after_host_reboot when needed" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect(nx).to receive(:incr_checkup)
      expect { nx.unavailable }.to hop("start_after_host_reboot")
    end

    it "register an immediate deadline if vm is unavailable" do
      expect(nx).to receive(:register_deadline).with("wait", 0)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "hops to wait if vm is available" do
      expect(nx).to receive(:available?).and_return(true)
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
        allow(vm).to receive(:update).with(display_state: "deleting")
        vol = instance_double(VmStorageVolume)
        dev = instance_double(StorageDevice)
        allow(Sequel).to receive(:[]).with(:available_storage_gib).and_return(100)
        allow(Sequel).to receive(:[]).with(:used_cores).and_return(1)
        allow(Sequel).to receive(:[]).with(:used_hugepages_1g).and_return(8)
        allow(vol).to receive(:storage_device_dataset).and_return(dev)
        allow(dev).to receive(:update).with(available_storage_gib: 105)
        allow(vol).to receive_messages(storage_device: dev, size_gib: 5)
        allow(vm).to receive_messages(vm_host: vm_host, vm_storage_volumes: [vol])
      end

      it "absorbs an already deleted errors as a success" do
        expect(sshable).to receive(:cmd).with("sudo timeout 10s systemctl stop #{nx.vm_name}").and_raise(
          Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
        )
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/).and_raise(
          Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
        )
        expect(sshable).to receive(:cmd).with(/sudo.*bin\/setup-vm delete #{nx.vm_name}/)

        expect { nx.destroy }.to hop("destroy_slice")
      end

      it "absorbs an already deleted errors as a success and hops to lb_expiry if vm is part of a load balancer" do
        expect(vm).to receive(:load_balancer).and_return(instance_double(LoadBalancer)).at_least(:once)
        expect(sshable).to receive(:cmd).with("sudo timeout 10s systemctl stop #{nx.vm_name}").and_raise(
          Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
        )
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/).and_raise(
          Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
        )
        expect(sshable).not_to receive(:cmd).with(/sudo.*bin\/setup-vm delete #{nx.vm_name}/)
        expect { nx.destroy }.to hop("remove_vm_from_load_balancer")
      end

      it "raises other stop errors" do
        ex = Sshable::SshError.new("stop", "", "unknown error", 1, nil)
        expect(sshable).to receive(:cmd).with("sudo timeout 10s systemctl stop #{nx.vm_name}").and_raise(ex)

        expect { nx.destroy }.to raise_error ex
      end

      it "raises other stop-dnsmasq errors" do
        ex = Sshable::SshError.new("stop", "", "unknown error", 1, nil)
        expect(sshable).to receive(:cmd).with("sudo timeout 10s systemctl stop #{nx.vm_name}")
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/).and_raise(ex)
        expect { nx.destroy }.to raise_error ex
      end

      it "deletes and pops when all commands are succeeded" do
        expect(sshable).to receive(:cmd).with("sudo timeout 10s systemctl stop #{nx.vm_name}")
        expect(sshable).to receive(:cmd).with(/sudo.*systemctl.*stop.*#{nx.vm_name}-dnsmasq/)
        expect(sshable).to receive(:cmd).with(/sudo.*bin\/setup-vm delete #{nx.vm_name}/)

        expect { nx.destroy }.to hop("destroy_slice")
      end
    end

    it "prevents destroy if the semaphore set" do
      expect(nx).to receive(:when_prevent_destroy_set?).and_yield
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore").and_call_original
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "detaches from pci devices" do
      ds = instance_double(Sequel::Dataset)
      expect(vm).to receive(:pci_devices_dataset).and_return(ds)
      expect(ds).to receive(:update).with(vm_id: nil)
      expect(vm).to receive(:update).with(display_state: "deleting")
      allow(vm).to receive(:vm_storage_volumes).and_return([])

      expect { nx.destroy }.to hop("destroy_slice")
    end

    it "updates slice" do
      vm_host_slice = instance_double(VmHostSlice)
      expect(vm).to receive(:vm_host_slice).and_return(vm_host_slice)
      expect(vm).to receive(:update).with(display_state: "deleting")
      expect { nx.destroy }.to hop("destroy_slice")
    end

    it "fails if VM cores is 0" do
      sshable = instance_double(Sshable)
      host = instance_double(VmHost, id: "46ca6ded-b056-4723-bd91-612959f52f6f", sshable: sshable)
      allow(sshable).to receive(:cmd)
      expect(vm).to receive(:update).with(display_state: "deleting")
      allow(vm).to receive(:vm_storage_volumes).and_return([])
      expect(vm).to receive(:vm_host_slice).and_return(nil)
      expect(vm).to receive(:cores).and_return(0)
      allow(nx).to receive(:host).and_return(host)
      expect { nx.destroy }.to raise_error(RuntimeError, "BUG: Number of cores cannot be zero when VM is runing without a slice")
    end

    it "skips updating host if host is nil" do
      allow(nx).to receive(:host).and_return(nil)
      expect(vm).to receive(:update).with(display_state: "deleting")
      expect(vm).not_to receive(:vm_host_id)
      expect { nx.destroy }.to hop("destroy_slice")
    end

    it "#destroy_slice when no slice" do
      expect(vm).to receive(:destroy).and_return(true)
      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
    end

    it "#destroy_slice with a slice" do
      vm_host_slice = instance_double(VmHostSlice, id: "9d487886-d167-4d00-8787-a746be0d4d9a")
      expect(vm).to receive(:vm_host_slice).and_return(vm_host_slice)
      expect(vm_host_slice).to receive(:incr_destroy)
      expect(vm).to receive(:destroy).and_return(true)

      vhs_dataset = instance_double(VmHostSlice.dataset.class)
      expect(vm_host_slice).to receive_messages(this: vhs_dataset)
      expect(vhs_dataset).to receive(:where).and_return(vhs_dataset)
      expect(vhs_dataset).to receive(:update).with(enabled: false).and_return(1)

      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
    end

    it "skips destroy slice when slice already disabled" do
      vm_host_slice = instance_double(VmHostSlice, id: "9d487886-d167-4d00-8787-a746be0d4d9a")
      expect(vm).to receive(:vm_host_slice).and_return(vm_host_slice)
      expect(vm).to receive(:destroy).and_return(true)

      vhs_dataset = instance_double(VmHostSlice.dataset.class)
      expect(vm_host_slice).to receive_messages(this: vhs_dataset)
      expect(vhs_dataset).to receive_messages(where: vhs_dataset)
      expect(vhs_dataset).to receive(:update).with(enabled: false).and_return(0)

      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
    end

    it "detaches from nic" do
      nic = instance_double(Nic)
      expect(nic).to receive(:update).with(vm_id: nil)
      expect(nic).to receive(:incr_destroy)
      expect(vm).to receive(:nics).and_return([nic])
      expect(vm).to receive(:destroy).and_return(true)
      allow(vm).to receive(:vm_storage_volumes).and_return([])

      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
    end

    it "hops to wait_aws_vm_destroyed if vm is in aws" do
      vm = instance_double(Vm, location: instance_double(Location, aws?: true), id: "vm_id")
      expect(vm).to receive(:update).with(display_state: "deleting")
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(nx).to receive(:bud).with(Prog::Aws::Instance, {"subject_id" => "vm_id"}, :destroy)
      expect { nx.destroy }.to hop("wait_aws_vm_destroyed")
    end
  end

  describe "#wait_aws_vm_destroyed" do
    it "reaps and pops if leaf" do
      st.update(prog: "Vm::Nexus", label: "wait_aws_vm_destroyed", stack: [{}])
      expect(nx).to receive(:final_clean_up)
      expect { nx.wait_aws_vm_destroyed }.to exit({"msg" => "vm deleted"})
    end

    it "naps if not leaf" do
      st.update(prog: "Vm::Nexus", label: "wait_aws_vm_destroyed", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Instance", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_aws_vm_destroyed }.to nap(10)
    end
  end

  describe "#remove_vm_from_load_balancer" do
    it "hops to wait_vm_removal_from_load_balancer" do
      expect(nx).to receive(:bud).with(Prog::Vnet::LoadBalancerRemoveVm, {"subject_id" => vm.id}, :mark_vm_ports_as_evacuating)
      expect { nx.remove_vm_from_load_balancer }.to hop("wait_vm_removal_from_load_balancer")
    end
  end

  describe "#wait_vm_removal_from_load_balancer" do
    let(:sshable) { instance_double(Sshable) }
    let(:vm_host) { instance_double(VmHost, sshable: sshable) }

    before do
      allow(vm).to receive(:vm_host).and_return(vm_host)
    end

    it "naps if vm is not removed" do
      st.update(prog: "Vm::Nexus", label: "wait_vm_removal_from_load_balancer", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Vnet::LoadBalancerRemoveVm", label: "evacuate_vm", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_vm_removal_from_load_balancer }.to nap(10)
    end

    it "hops to destroy_slice if vm is removed" do
      expect(nx).to receive(:reap).and_yield
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo host/bin/setup-vm delete_net #{vm.inhost_name}")
      expect { nx.wait_vm_removal_from_load_balancer }.to hop("destroy_slice")
    end

    it "handles the case when the vm_host is not set" do
      expect(nx).to receive(:reap).and_yield.twice

      expect(vm.vm_host).to receive(:sshable).and_return(nil)
      expect { nx.wait_vm_removal_from_load_balancer }.to hop("destroy_slice")

      expect(vm).to receive(:vm_host).and_return(nil)
      expect { nx.wait_vm_removal_from_load_balancer }.to hop("destroy_slice")
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
