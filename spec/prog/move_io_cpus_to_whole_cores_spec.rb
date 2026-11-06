# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::MoveIoCpusToWholeCores do
  subject(:nx) { described_class.new(described_class.assemble(vm_host.id)) }

  # Core N is cpus N and N + 4, and the io cpus are the old cpus 0 and 1.
  let(:vm_host) { create_vm_host(total_cpus: 8, total_cores: 4, accepts_slices: true) }

  before do
    VmHostCpu.import([:vm_host_id, :cpu_number, :io, :core_number], (0..7).map { [vm_host.id, it, it < 2, it % 4] })
  end

  describe ".assemble" do
    it "fails if the VmHost does not exist" do
      expect {
        described_class.assemble(VmHost.generate_uuid)
      }.to raise_error RuntimeError, "No existing VmHost"
    end

    it "creates a strand pointed at the given VmHost" do
      st = described_class.assemble(vm_host.id)
      expect(st.prog).to eq "MoveIoCpusToWholeCores"
      expect(st.label).to eq "start"
      expect(described_class.new(st).vm_host.id).to eq vm_host.id
    end
  end

  describe "#start" do
    it "exits without changes if the host does not accept slices" do
      vm_host.update(accepts_slices: false)
      expect { nx.start }.to exit({"msg" => "VmHost does not accept slices, so its io cpus need no change"})
      expect(vm_host.cpus_dataset.where(io: true).select_order_map(:cpu_number)).to eq [0, 1]
    end

    it "fails if a cpu has no core number" do
      VmHostCpu.where(vm_host_id: vm_host.id, cpu_number: 7).update(core_number: nil)
      expect { nx.start }.to raise_error RuntimeError, "VmHost has cpus without a core number"
    end

    it "exits without changes if the host runs SPDK" do
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 0, cpu_count: 2, hugepages: 2)
      expect { nx.start }.to exit({"msg" => "VmHost runs SPDK, whose reactors are pinned to the old io cpus, so its io cpus are left as they are"})
      expect(vm_host.cpus_dataset.where(io: true).select_order_map(:cpu_number)).to eq [0, 1]
    end

    it "hops to move the io cpus" do
      expect { nx.start }.to hop("move_io_cpus")
    end
  end

  describe "#move_io_cpus" do
    it "waits while a slice uses a cpu of the io core" do
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vm_host, family: "standard", allowed_cpus: [4], memory_gib: 4)
      expect { nx.move_io_cpus }.to nap(30)
      expect(vm_host.cpus_dataset.where(io: true).select_order_map(:cpu_number)).to eq [0, 1]
    end

    it "moves the io cpus to the whole io core and hops to update the storage daemons" do
      expect { nx.move_io_cpus }.to hop("update_storage_daemons")
      expect(vm_host.cpus_dataset.where(io: true).select_order_map(:cpu_number)).to eq [0, 4]
    end
  end

  describe "#update_storage_daemons" do
    before do
      VmHostCpu.where(vm_host_id: vm_host.id, cpu_number: 1).update(io: false)
      VmHostCpu.where(vm_host_id: vm_host.id, cpu_number: 4).update(io: true)
    end

    let(:backend) { VhostBlockBackend.create(vm_host_id: vm_host.id, allocation_weight: 100, version_code: 1) }

    def create_vm_on_host(cpus, **)
      slice = Prog::Vm::VmHostSliceNexus.assemble_with_host("sl#{cpus.first}", vm_host, family: "standard", allowed_cpus: cpus, memory_gib: 4).subject if cpus
      vm = create_vm(vm_host_id: vm_host.id, vm_host_slice_id: slice&.id, **)
      VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, vhost_block_backend_id: backend.id, vring_workers: 1)
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 0, disk_index: 1)
      vm
    end

    it "lets the storage daemons of running VMs in slices use the new io cpus and pops" do
      vm = create_vm_on_host([2, 6])
      create_vm_on_host([3, 7], display_state: "creating")
      create_vm_on_host(nil)

      expect(nx.sshable).to receive(:_cmd).with("sudo systemctl set-property #{vm.inhost_name}-0-storage.service AllowedCPUs=0,2,4,6")
      expect { nx.update_storage_daemons }.to exit({"msg" => "moved io cpus to whole cores"})
    end

    it "pops without a command when no storage daemon needs updating" do
      expect { nx.update_storage_daemons }.to exit({"msg" => "moved io cpus to whole cores"})
    end
  end
end
