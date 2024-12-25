# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::VmPool do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new }

  describe ".assemble" do
    it "creates the entity and strand properly" do
      st = described_class.assemble(
        size: 3, vm_size: "standard-2", boot_image: "img", location: "hetzner-fsn1",
        storage_size_gib: 86, storage_encrypted: true,
        storage_skip_sync: false, arch: "x64"
      )
      pool = VmPool[st.id]
      expect(pool).not_to be_nil
      expect(pool.size).to eq(3)
      expect(pool.vm_size).to eq("standard-2")
      expect(pool.boot_image).to eq("img")
      expect(pool.location).to eq("hetzner-fsn1")
      expect(pool.storage_size_gib).to eq(86)
      expect(pool.storage_encrypted).to be(true)
      expect(pool.storage_skip_sync).to be(false)
      expect(st.label).to eq("create_new_vm")
    end
  end

  describe "#create_new_vm" do
    let(:prj) {
      Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
    }

    it "creates a new vm and hops to wait" do
      expect(Config).to receive(:vm_pool_project_id).and_return(prj.id).at_least(:once)
      st = described_class.assemble(
        size: 3, vm_size: "standard-2", boot_image: "img", location: "hetzner-fsn1",
        storage_size_gib: 86, storage_encrypted: true,
        storage_skip_sync: false, arch: "arm64"
      )
      st.update(label: "create_new_vm")
      expect(SshKey).to receive(:generate).and_call_original
      expect(nx).to receive(:vm_pool).and_return(VmPool[st.id]).at_least(:once)
      expect { nx.create_new_vm }.to hop("wait")
      pool = VmPool[st.id]
      expect(pool.vms.count).to eq(1)
      expect(pool.vms.first.sshable).not_to be_nil
    end
  end

  describe "#wait" do
    before do
      VmHost.create(location: "github-runners", allocation_state: "accepting", arch: "x64", total_cores: 2, used_cores: 0) { _1.id = Sshable.create_with_id.id }
    end

    let(:pool) {
      VmPool.create_with_id(
        size: 0, vm_size: "standard-2", boot_image: "img", location: "hetzner-fsn1",
        storage_size_gib: 86, storage_encrypted: true,
        storage_skip_sync: false, arch: "x64"
      )
    }

    it "waits if nothing to do" do
      expect(nx).to receive(:vm_pool).and_return(pool).at_least(:once)
      expect { nx.wait }.to nap(30)
    end

    it "hops to create_new_vm if there are enough idle cores" do
      pool.update(size: 1)
      expect(nx).to receive(:vm_pool).and_return(pool).at_least(:once)

      expect { nx.wait }.to hop("create_new_vm")
    end

    it "hops to create_new_vm if there are enough idle cores for the given arch" do
      pool.update(size: 1)

      expect(nx).to receive(:vm_pool).and_return(pool).at_least(:once)
      Vm.create(vm_host: VmHost.first, unix_user: "ubi", public_key: "key", name: "vm1", location: "github-runners", boot_image: "github-ubuntu-2204", family: "standard", arch: "arm64", cores: 4, vcpus: 2, memory_gib: 8) { _1.id = Sshable.create_with_id.id }

      expect { nx.wait }.to hop("create_new_vm")
    end

    it "waits if there are not enough idle cores due to waiting github runners" do
      pool.update(size: 1)

      expect(nx).to receive(:vm_pool).and_return(pool).at_least(:once)
      Vm.create(vm_host: VmHost.first, unix_user: "ubi", public_key: "key", name: "vm1", location: "github-runners", boot_image: "github-ubuntu-2204", family: "standard", arch: "x64", cores: 2, vcpus: 2, memory_gib: 8) { _1.id = Sshable.create_with_id.id }

      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    let(:pool) {
      VmPool.create_with_id(size: 0, vm_size: "standard-2", boot_image: "img", location: "hetzner-fsn1", storage_size_gib: 86)
    }

    it "increments vms' destroy semaphore and hops to wait_vms_destroy" do
      ps = instance_double(PrivateSubnet)
      vm = instance_double(Vm, private_subnets: [ps])
      expect(nx).to receive(:vm_pool).and_return(pool)
      expect(pool).to receive(:vms).and_return([vm])
      expect(vm).to receive(:incr_destroy)
      expect(ps).to receive(:incr_destroy)
      expect { nx.destroy }.to hop("wait_vms_destroy")
    end
  end

  describe "#wait_vms_destroy" do
    let(:pool) {
      VmPool.create_with_id(size: 0, vm_size: "standard-2", boot_image: "img", location: "hetzner-fsn1", storage_size_gib: 86)
    }

    it "pops if vms are all destroyed" do
      expect(nx).to receive(:vm_pool).and_return(pool).at_least(:once)
      expect(pool).to receive(:destroy)
      expect(pool).to receive(:vms).and_return([])

      expect { nx.wait_vms_destroy }.to exit({"msg" => "pool destroyed"})
    end

    it "naps if there are still vms" do
      expect(nx).to receive(:vm_pool).and_return(pool).at_least(:once)
      expect(pool).to receive(:vms).and_return([true])
      expect { nx.wait_vms_destroy }.to nap(10)
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
  end
end
