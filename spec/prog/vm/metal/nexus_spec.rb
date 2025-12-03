# frozen_string_literal: true

require_relative "../../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Metal::Nexus do
  subject(:nx) {
    described_class.new(vm.strand).tap {
      it.instance_variable_set(:@vm, vm)
      it.instance_variable_set(:@host, vm_host)
    }
  }

  let(:st) { vm.strand }
  let(:vm_host) { create_vm_host(used_cores: 2, total_hugepages_1g: 375, used_hugepages_1g: 16) }
  let(:sshable) { vm_host.sshable }
  let(:vm) {
    vm = Vm.create_with_id(
      "2464de61-7501-8374-9ab0-416caebe31da",
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
      created_at: Time.now,
      project_id: project.id,
      vm_host_id: vm_host.id
    )
    Strand.create_with_id(vm.id, prog: "Vm::Metal::Nexus", label: "start")
    vm
  }
  let(:project) { Project.create(name: "default") }
  let(:private_subnet) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: project.id)
  }
  let(:nic) {
    Nic.create(private_subnet_id: private_subnet.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      state: "active")
  }

  describe ".assemble" do
    it "fails if there is no project" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing project"
    end

    it "fails if location doesn't exist" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: nil)
      }.to raise_error RuntimeError, "No existing location"
    end

    it "creates Subnet and Nic if not passed" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id)
      }.to change(PrivateSubnet, :count).from(0).to(1)
        .and change(Nic, :count).from(0).to(1)
    end

    it "creates Nic if only subnet_id is passed" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, private_subnet_id: private_subnet.id)
      }.to change(Nic, :count).from(0).to(1)
      expect(PrivateSubnet.count).to eq(1)
    end

    it "adds the VM to a private subnet if nic_id is passed" do
      expect(Prog::Vnet::SubnetNexus).not_to receive(:assemble)
      expect(Prog::Vnet::NicNexus).not_to receive(:assemble)
      Prog::Vm::Nexus.assemble("some_ssh key", project.id, nic_id: nic.id, location_id: Location::HETZNER_FSN1_ID)
    end

    it "creates with default storage size from vm size" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id)
      expect(st.stack.first["storage_volumes"].first["size_gib"]).to eq(Option::VmSizes.first.storage_size_options.first)
    end

    it "creates with custom storage size if provided" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, storage_volumes: [{size_gib: 40}])
      expect(st.stack.first["storage_volumes"].first["size_gib"]).to eq(40)
    end

    it "fails if given nic_id is not valid" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, nic_id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given nic doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if given subnet_id is not valid" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, private_subnet_id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if nic is assigned to a different vm" do
      nic.update(vm_id: vm.id)
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is assigned to a VM already"
    end

    it "fails if nic subnet is in another location" do
      private_subnet.update(location_id: Location::LEASEWEB_WDC02_ID)
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is created in a different location"
    end

    it "fails if subnet of nic belongs to another project" do
      private_subnet.update(project_id: Project.create(name: "project-2").id)
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is not available in the given project"
    end

    it "fails if subnet belongs to another project" do
      private_subnet.update(project_id: Project.create(name: "project-2").id)
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, private_subnet_id: private_subnet.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the given project"
    end

    it "allows if subnet belongs to another project and allow_private_subnet_in_other_project argument is given" do
      private_subnet.update(project_id: Project.create(name: "project-2").id)
      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, private_subnet_id: private_subnet.id, allow_private_subnet_in_other_project: true).subject
      expect(vm.private_subnets.map(&:id)).to eq [private_subnet.id]
    end

    it "creates arm64 vm with double core count and 3.2GB memory per core" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, size: "standard-4", arch: "arm64")
      expect(st.subject.vcpus).to eq(4)
      expect(st.subject.memory_gib).to eq(12)
    end

    it "requests as many gpus as specified" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, size: "standard-2", gpu_count: 2)
      expect(st.stack.first["gpu_count"]).to eq(2)
    end

    it "requests at least a single gpu for standard-gpu-6" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, size: "standard-gpu-6")
      expect(st.stack.first["gpu_count"]).to eq(1)
    end

    it "requests no gpus by default" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, size: "standard-2")
      expect(st.stack.first["gpu_count"]).to eq(0)
    end

    it "fails if same host is forced and excluded" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id,
          force_host_id: "some-vm-host-id", exclude_host_ids: ["some-vm-host-id"])
      }.to raise_error RuntimeError, "Cannot force and exclude the same host"
    end
  end

  describe ".assemble_with_sshable" do
    it "calls .assemble with generated ssh key" do
      st_id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5"
      expect(SshKey).to receive(:generate).and_return(instance_double(SshKey, public_key: "public", keypair: "pair"))
      st = Strand.new(id: st_id)
      expect(Prog::Vm::Nexus).to receive(:assemble) do |public_key, project_id, **kwargs|
        expect(public_key).to eq("public")
        expect(project_id).to eq(project.id)
        expect(kwargs[:name]).to be_nil
        expect(kwargs[:size]).to eq("new_size")
      end.and_return(st)
      expect(Sshable).to receive(:create_with_id).with(st, host: "temp_#{st_id}", raw_private_key_1: "pair", unix_user: "rhizome")

      Prog::Vm::Nexus.assemble_with_sshable(project.id, size: "new_size")
    end
  end

  describe "#create_unix_user" do
    it "runs adduser" do
      expect(nx).to receive(:rand).and_return(1111)
      expect(sshable).to receive(:_cmd).with(<<~COMMAND)
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
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("Succeeded")
      expect { nx.prep }.to hop("clean_prep")
    end

    [
      {"swap_size_bytes" => nil},
      {"swap_size_bytes" => nil, "hugepages" => false, "hypervisor" => "ch", "ch_version" => "46.0", "firmware_version" => "202311"}
    ].each do |frame_update|
      it "generates and passes a params json if prep command is not started yet (with frame opts: #{frame_update.inspect})" do
        kek = StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "key", init_vector: "iv", auth_data: "somedata")
        si = SpdkInstallation.create(version: "v1", allocation_weight: 100, vm_host_id: vm_host.id)
        bi = BootImage.create(name: "my-image", version: "20230303", size_gib: 15, vm_host_id: vm_host.id)
        dev1 = StorageDevice.create(name: "nvme0", total_storage_gib: 1000, available_storage_gib: 500)
        dev2 = StorageDevice.create(name: "DEFAULT", total_storage_gib: 1000, available_storage_gib: 500)
        VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false, spdk_installation_id: si.id, storage_device_id: dev1.id, key_encryption_key_1_id: kek.id)
        VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 15, disk_index: 1, use_bdev_ubi: true, skip_sync: true, spdk_installation_id: si.id, storage_device_id: dev2.id, boot_image_id: bi.id)

        st.stack = [frame_update]
        vm.ephemeral_net6 = "fe80::/64"
        vm.unix_user = "test_user"
        vm.public_key = "test_ssh_key"
        vm.local_vetho_ip = NetAddr::IPv4Net.parse("169.254.0.0/32")
        private_subnet.update(net4: NetAddr::IPv4Net.parse("10.0.0.0/26"))
        nic.update(vm_id: vm.id, private_ipv6: "fd10:9b0b:6b4b:8fbb::/64", private_ipv4: "10.0.0.3/32", mac: "5a:0f:75:80:c3:64")
        expect(vm.nic.private_subnet).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/64")
        PciDevice.create(vm_id: vm.id, vm_host_id: vm_host.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 23)
        expect(vm).to receive(:cloud_hypervisor_cpu_topology).and_return(Vm::CloudHypervisorCpuTopo.new(2, 1, 1, 1))

        project.set_ff_vm_public_ssh_keys(["operator_ssh_key"])
        project.set_ff_ipv6_disabled(true)

        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("NotStarted")
        expect(sshable).to receive(:_cmd).with(/sudo -u vm[0-9a-z]+ tee/, stdin: String) do |**kwargs|
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
            "local_ipv4" => "169.254.0.0/32",
            "nics" => [["fd10:9b0b:6b4b:8fbb::/64", "10.0.0.3/32", nic.ubid_to_tap_name, "5a:0f:75:80:c3:64", "10.0.0.1/26"]],
            "swap_size_bytes" => nil,
            "pci_devices" => [["01:00.0", 23]],
            "slice_name" => "system.slice",
            "cpu_percent_limit" => 200,
            "cpu_burst_percent_limit" => 0,
            **frame_update
          )
        end
        expect(sshable).to receive(:_cmd).with(/sudo host\/bin\/setup-vm prep #{nx.vm_name}/, {stdin: /{"storage":{"vm.*_0":{"key":"key","init_vector":"iv","algorithm":"aes-256-gcm","auth_data":"somedata"}}}/})

        expect { nx.prep }.to nap(1)
      end
    end

    it "naps if prep command is in progress" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check prep_#{nx.vm_name}").and_return("InProgress")
      expect { nx.prep }.to nap(1)
    end
  end

  describe "#clean_prep" do
    it "cleans and hops" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean prep_/)
      expect { nx.clean_prep }.to hop("wait_sshable")
    end
  end

  describe "#start" do
    let(:storage_volumes) {
      [{
        "use_bdev_ubi" => false,
        "skip_sync" => true,
        "size_gib" => 11,
        "boot" => true
      }]
    }

    before do
      st.stack = [{"storage_volumes" => storage_volumes}]
    end

    it "creates a page if no capacity left and naps" do
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host")).twice
      expect(vm.waiting_for_capacity_set?).to be(false)
      expect { nx.start }.to nap(30)
      expect(vm.reload.waiting_for_capacity_set?).to be(true)
      expect(Page.active.count).to eq(1)
      expect(Page.from_tag_parts("NoCapacity", Location[vm.location_id].display_name, vm.arch, vm.family)).not_to be_nil

      # Second run does not generate another page
      expect(nx).not_to receive(:incr_waiting_for_capacity)
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)
    end

    it "waits for a while before creating a page for github-runners" do
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host"))

      vm.created_at = Time.now - 10 * 60
      vm.location_id = Location[name: "github-runners"].id
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(0)
    end

    it "resolves the page if no VM left in the queue after 15 minutes" do
      # First run creates the page
      expect(Scheduling::Allocator).to receive(:allocate).and_raise(RuntimeError.new("no space left on any eligible host"))
      expect { nx.start }.to nap(30)
      expect(Page.active.count).to eq(1)

      # Second run is able to allocate, but there are still vms in the queue, so we don't resolve the page
      expect(Scheduling::Allocator).to receive(:allocate)
      expect { nx.start }.to hop("create_unix_user")
        .and change { vm.reload.waiting_for_capacity_set? }.from(true).to(false)
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
        vm, storage_volumes,
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
        vm, storage_volumes,
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
        vm, storage_volumes,
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
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id, created_at: Time.now - 8 * 24 * 60 * 60, allocator_preferences: {"location_filter" => [Location::GITHUB_RUNNERS_ID, Location::LEASEWEB_WDC02_ID]})
      GithubRunner.create(vm_id: vm.id, repository_name: "ubicloud/test", label: "ubicloud", installation_id: installation.id)
      vm.location_id = Location::GITHUB_RUNNERS_ID

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id, created_at: Time.now - 8 * 24 * 60 * 60, allocator_preferences: {
        "location_filter" => [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID, Location::LEASEWEB_WDC02_ID],
        "location_preference" => [Location::LEASEWEB_WDC02_ID]
      })
      GithubRunner.create(vm_id: vm.id, repository_name: "ubicloud/test", label: "ubicloud", installation_id: installation.id)
      vm.location_id = Location::GITHUB_RUNNERS_ID

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      GithubRunner.create(label: "ubicloud", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id)
      GithubRunner.create(label: "ubicloud", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
      project.set_ff_free_runner_upgrade_until(Time.now + 5 * 24 * 60 * 60)
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      GithubRunner.create(label: "ubicloud-premium-30", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      runner = Prog::Github::GithubRunnerNexus.assemble(installation, repository_name: "ubicloud/test", label: "ubicloud-standard-2").subject.update(vm_id: vm.id)
      runner.incr_not_upgrade_premium
      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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

    it "uses standard-gpu family even if premium enabled" do
      vm.location_id = Location::GITHUB_RUNNERS_ID
      vm.family = "standard-gpu"
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: project.id, allocator_preferences: {"family_filter" => ["standard", "premium"]})
      GithubRunner.create(label: "ubicloud-gpu", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [],
        location_filter: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID],
        location_preference: [Location::GITHUB_RUNNERS_ID],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard-gpu"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "can force allocating a host" do
      st.stack = [{
        "force_host_id" => vm_host.id,
        "storage_volumes" => storage_volumes
      }]

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
        allocation_state_filter: [],
        distinct_storage_devices: false,
        host_filter: [vm_host.id],
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
      st.stack = [{
        "exclude_host_ids" => [vm_host.id, "another-vm-host-id"],
        "storage_volumes" => storage_volumes
      }]

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
        allocation_state_filter: ["accepting"],
        distinct_storage_devices: false,
        host_filter: [],
        host_exclusion_filter: [vm_host.id, "another-vm-host-id"],
        location_filter: [Location::HETZNER_FSN1_ID],
        location_preference: [],
        gpu_count: 0,
        gpu_device: nil,
        family_filter: ["standard"]
      )
      expect { nx.start }.to hop("create_unix_user")
    end

    it "requests distinct storage devices" do
      st.stack = [{
        "distinct_storage_devices" => true,
        "storage_volumes" => storage_volumes,
        "gpu_count" => 0
      }]

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      st.stack = [{
        "gpu_count" => 3,
        "storage_volumes" => storage_volumes
      }]

      expect(Scheduling::Allocator).to receive(:allocate).with(
        vm, storage_volumes,
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
      st.update(stack: [{"storage_volumes" => [{"size_gib" => 11}]}])
      expect { nx.clear_stack_storage_volumes }.to change { st.reload.stack.first["storage_volumes"] }.from([{"size_gib" => 11}]).to(nil)
    end
  end

  describe "#wait_sshable" do
    it "naps 6 seconds if it's the first time we execute wait_sshable" do
      expect { nx.wait_sshable }.to nap(6)
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
    end

    it "naps if not sshable" do
      expect(vm).to receive(:ip4).and_return(NetAddr::IPv4.parse("10.0.0.1"))
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      vm.incr_update_firewall_rules
      adr = Address.create(cidr: "10.0.0.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "10.0.0.1", address_id: adr.id, dst_vm_id: vm.id)
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "skips a check if ipv4 is not enabled" do
      vm.incr_update_firewall_rules
      expect(vm.ip4).to be_nil
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end
  end

  describe "#create_billing_record" do
    let(:now) { Time.now }

    before do
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      vm.update(allocated_at: now - 100)
      expect(Clog).to receive(:emit).with("vm provisioned").and_yield
    end

    it "not create billing records when the project is not billable" do
      project.update(billable: false)
      expect { nx.create_billing_record }.to hop("wait")
      expect(BillingRecord.count).to eq(0)
    end

    it "creates billing records for only vm" do
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
      expect(vm.active_billing_records.first.billing_rate["resource_type"]).to eq("VmVCpu")
      expect(vm.display_state).to eq("running")
      expect(vm.provisioned_at).to eq(now)
    end

    it "creates billing records when storage volumes are present" do
      2.times {
        dev = StorageDevice.create(name: "disk_#{it}", total_storage_gib: it * 1000, available_storage_gib: it * 500)
        VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: it, use_bdev_ubi: false, skip_sync: false, storage_device_id: dev.id)
      }

      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(3)
      expect(vm.active_billing_records.map { it.billing_rate["resource_type"] }.sort).to eq(["VmStorage", "VmStorage", "VmVCpu"])
    end

    it "creates billing records when ip4 is enabled" do
      vm.ip4_enabled = true
      adr = Address.create(cidr: "192.168.1.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(2)
      expect(vm.active_billing_records.map { it.billing_rate["resource_type"] }.sort).to eq(["IPAddress", "VmVCpu"])
    end

    it "creates billing records when gpu is present" do
      vm.location_id = Location[name: "latitude-ai"].id
      PciDevice.create(vm_id: vm.id, vm_host_id: vm_host.id, slot: "01:00.0", iommu_group: 23, device_class: "0302", vendor: "10de", device: "20b5")
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(2)
      expect(vm.active_billing_records.map { it.billing_rate["resource_type"] }.sort).to eq(["Gpu", "VmVCpu"])
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      vm.incr_destroy
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      ["destroy", "destroy_slice", "remove_vm_from_load_balancer"].each do |label|
        vm.incr_destroy
        st.label = label
        expect { nx.before_run }.not_to hop("destroy")
      end
    end

    it "stops billing before hops to destroy" do
      adr = Address.create(cidr: "192.168.1.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)

      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus
      )

      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.assigned_vm_address.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location.name)["id"],
        amount: 1
      )

      vm.incr_destroy
      vm.active_billing_records.each { expect(it).to receive(:finalize).and_call_original }
      expect(vm.assigned_vm_address.active_billing_record).to receive(:finalize).and_call_original
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found" do
      vm.incr_destroy
      expect(vm.active_billing_records).to be_empty
      expect(vm.assigned_vm_address).to be_nil
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found for ipv4" do
      vm.incr_destroy
      adr = Address.create(cidr: "192.168.1.0/24", routed_to_host_id: vm_host.id)
      AssignedVmAddress.create(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)
      expect(vm.assigned_vm_address).not_to be_nil
      expect(vm.assigned_vm_address.active_billing_record).to be_nil

      expect { nx.before_run }.to hop("destroy")
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to start_after_host_reboot when needed" do
      vm.incr_start_after_host_reboot
      expect { nx.wait }.to hop("start_after_host_reboot")
    end

    it "hops to update_spdk_dependency when needed" do
      vm.incr_update_spdk_dependency
      expect { nx.wait }.to hop("update_spdk_dependency")
    end

    it "hops to update_firewall_rules when needed" do
      vm.incr_update_firewall_rules
      expect { nx.wait }.to hop("update_firewall_rules")
    end

    it "hops to restart when needed" do
      vm.incr_restart
      expect { nx.wait }.to hop("restart")
    end

    it "hops to stopped when needed" do
      vm.incr_stop
      expect { nx.wait }.to hop("stopped")
    end

    it "hops to unavailable based on the vm's available status" do
      vm.incr_checkup
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      vm.incr_checkup
      expect(nx).to receive(:available?).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect { nx.wait }.to hop("unavailable")

      vm.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#update_firewall_rules" do
    it "hops to wait_firewall_rules" do
      vm.incr_update_firewall_rules
      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: false))
      expect(nx).to receive(:push).with(Prog::Vnet::Metal::UpdateFirewallRules, {}, :update_firewall_rules)
      expect { nx.update_firewall_rules }
        .to change { vm.reload.update_firewall_rules_set? }.from(true).to(false)
    end

    it "hops to wait if firewall rules are applied" do
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rule is added"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#update_spdk_dependency" do
    it "hops to wait after doing the work" do
      vm.incr_update_spdk_dependency
      expect(nx).to receive(:write_params_json)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm reinstall-systemd-units #{vm.inhost_name}")
      expect { nx.update_spdk_dependency }.to hop("wait")
        .and change { vm.reload.update_spdk_dependency_set? }.from(true).to(false)
    end
  end

  describe "#restart" do
    it "hops to wait after restarting the vm" do
      vm.incr_restart
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm restart #{vm.inhost_name}")
      expect { nx.restart }.to hop("wait")
        .and change { vm.reload.restart_set? }.from(true).to(false)
    end
  end

  describe "#stopped" do
    it "naps after stopping the vm" do
      vm.incr_stop
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{vm.inhost_name}")
      expect { nx.stopped }.to nap(60 * 60)
        .and change { vm.reload.stop_set? }.from(true).to(false)
    end

    it "does not stop if already stopped" do
      expect(vm.stop_set?).to be(false)
      expect { nx.stopped }.to nap(60 * 60)
    end
  end

  describe "#unavailable" do
    it "hops to start_after_host_reboot when needed" do
      vm.incr_start_after_host_reboot
      expect { nx.unavailable }.to hop("start_after_host_reboot")
        .and change { vm.reload.checkup_set? }.from(false).to(true)
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
    it "prevents destroy if the semaphore set" do
      vm.incr_prevent_destroy
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore").and_call_original
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "absorbs an already deleted errors as a success" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10).and_raise(
        Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
      )
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq").and_raise(
        Sshable::SshError.new("stop", "", "Failed to stop #{nx.vm_name} Unit .* not loaded.", 1, nil)
      )
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      expect { nx.destroy }.to hop("destroy_slice")
    end

    it "raises unexpected vm stop errors" do
      ex = Sshable::SshError.new("stop", "", "unknown error", 1, nil)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10).and_raise(ex)

      expect { nx.destroy }.to raise_error ex
    end

    it "raises unexpected dnsmasq stop errors" do
      ex = Sshable::SshError.new("stop", "", "unknown error", 1, nil)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq").and_raise(ex)
      expect { nx.destroy }.to raise_error ex
    end

    it "hops when all commands are succeeded" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      expect { nx.destroy }.to hop("destroy_slice")
      expect(vm.display_state).to eq("deleting")
      vm_host.reload
      expect(vm_host.used_cores).to eq(1)
      expect(vm_host.used_hugepages_1g).to eq(8)
    end

    it "updates storage devices" do
      dev = StorageDevice.create(name: "DEFAULT", total_storage_gib: 1000, available_storage_gib: 500)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false, storage_device_id: dev.id)

      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      expect { nx.destroy }.to hop("destroy_slice")
        .and change { dev.reload.available_storage_gib }.from(500).to(520)
    end

    it "hops to lb_expiry if vm is part of a load balancer" do
      expect(vm).to receive(:load_balancer).and_return(instance_double(LoadBalancer)).at_least(:once)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete_keep_net #{nx.vm_name}")

      expect { nx.destroy }.to hop("remove_vm_from_load_balancer")
    end

    it "detaches from pci devices" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      pci = PciDevice.create(vm_id: vm.id, vm_host_id: vm_host.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 3)
      expect(pci.vm).to eq(vm)
      expect { nx.destroy }.to hop("destroy_slice")
      expect(pci.reload.vm).to be_nil
    end

    it "detaches from gpu partition" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      pci = PciDevice.create(vm_host_id: vm_host.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 3)
      gp = GpuPartition.create(vm_id: vm.id, vm_host_id: vm_host.id, partition_id: 1, gpu_count: 1)
      DB[:gpu_partitions_pci_devices].insert(gpu_partition_id: gp.id, pci_device_id: pci.id)

      expect { nx.destroy }.to hop("destroy_slice")
        .and change { gp.reload.vm_id }.from(vm.id).to(nil)
    end

    it "updates slice" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      slice = VmHostSlice.create(vm_host_id: vm_host.id, name: "standard", family: "standard", cores: 1, total_cpu_percent: 200, used_cpu_percent: 200, total_memory_gib: 8, used_memory_gib: 8)
      vm.update(vm_host_slice_id: slice.id)

      expect { nx.destroy }.to hop("destroy_slice")
        .and change { [slice.reload.used_cpu_percent, slice.used_memory_gib] }.from([200, 8]).to([0, 0])
    end

    it "fails if VM cores is 0" do
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}", timeout: 10)
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop #{nx.vm_name}-dnsmasq")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete #{nx.vm_name}")

      vm.cores = 0

      expect { nx.destroy }.to raise_error(RuntimeError, "BUG: Number of cores cannot be zero when VM is runing without a slice")
    end

    it "skips updating host if host is nil" do
      vm.update(vm_host_id: nil)
      expect(nx).to receive(:host).and_return(nil).at_least(:once)

      expect { nx.destroy }.to hop("destroy_slice")
    end
  end

  describe "#destroy_slice" do
    it "#destroy_slice when no slice" do
      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
      expect(vm.exists?).to be(false)
    end

    it "#destroy_slice with a slice" do
      vm_host_slice = VmHostSlice.create(vm_host_id: vm_host.id, enabled: true, name: "standard", family: "standard", cores: 1, total_cpu_percent: 200, used_cpu_percent: 0, total_memory_gib: 8, used_memory_gib: 0)
      Strand.create_with_id(vm_host_slice.id, prog: "Vm::VmHostSliceNexus", label: "prep")
      vm.update(vm_host_slice_id: vm_host_slice.id)

      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
      expect(vm_host_slice.reload.enabled).to be(false)
      expect(Semaphore[strand_id: vm_host_slice.id, name: "destroy"]).not_to be_nil
      expect(vm.exists?).to be(false)
    end

    it "skips destroy slice when slice already disabled" do
      vm_host_slice = VmHostSlice.create(vm_host_id: vm_host.id, enabled: false, name: "standard", family: "standard", cores: 1, total_cpu_percent: 200, used_cpu_percent: 0, total_memory_gib: 8, used_memory_gib: 0)
      Strand.create_with_id(vm_host_slice.id, prog: "Vm::VmHostSliceNexus", label: "prep")
      vm.update(vm_host_slice_id: vm_host_slice.id)

      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
      expect(vm_host_slice.reload.enabled).to be(false)
      expect(Semaphore[strand_id: vm_host_slice.id, name: "destroy"]).to be_nil
      expect(vm.exists?).to be(false)
    end
  end

  describe "#final_clean_up" do
    it "detaches from nic" do
      nic.update(vm_id: vm.id)
      Strand.create_with_id(nic.id, prog: "Vnet::NicNexus", label: "start")

      expect { nx.destroy_slice }.to exit({"msg" => "vm deleted"})
        .and change { nic.reload.destroy_set? }.from(false).to(true)
        .and change(nic, :vm_id).from(vm.id).to(nil)
      expect(vm.exists?).to be(false)
    end
  end

  describe "#remove_vm_from_load_balancer" do
    it "hops to wait_vm_removal_from_load_balancer" do
      expect(nx).to receive(:bud).with(Prog::Vnet::LoadBalancerRemoveVm, {"subject_id" => vm.id}, :mark_vm_ports_as_evacuating)
      expect { nx.remove_vm_from_load_balancer }.to hop("wait_vm_removal_from_load_balancer")
    end
  end

  describe "#wait_vm_removal_from_load_balancer" do
    it "naps if vm is not removed" do
      st.update(prog: "Vm::Nexus", label: "wait_vm_removal_from_load_balancer", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Vnet::LoadBalancerRemoveVm", label: "evacuate_vm", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_vm_removal_from_load_balancer }.to nap(10)
    end

    it "hops to destroy_slice if vm is removed" do
      expect(nx).to receive(:reap).and_yield
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-vm delete_net #{vm.inhost_name}")
      expect { nx.wait_vm_removal_from_load_balancer }.to hop("destroy_slice")
    end

    it "handles the case when the vm_host is not set" do
      expect(nx).to receive(:reap).and_yield

      expect(nx).to receive(:host).and_return(nil).at_least(:once)
      expect { nx.wait_vm_removal_from_load_balancer }.to hop("destroy_slice")
    end
  end

  describe "#start_after_host_reboot" do
    it "can start a vm after reboot" do
      kek = StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "key", init_vector: "iv", auth_data: "somedata")
      dev = StorageDevice.create(name: "nvme0", total_storage_gib: 1000, available_storage_gib: 500)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, skip_sync: false, storage_device_id: dev.id, key_encryption_key_1_id: kek.id)

      expect(sshable).to receive(:_cmd).with(
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
      expect(sshable).to receive(:_cmd).and_return("active\nactive\n")
      expect(vm).to receive(:inhost_name).and_return("vmxxxx").at_least(:once)
      expect(nx.available?).to be true
    end
  end
end
