# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::VmPool do
  subject(:nx) {
    described_class.new(st).tap {
      it.instance_variable_set(:@vm_pool, pool)
    }
  }

  let(:st) { Strand.new }

  let(:project_id) { Project.create(name: "test-project").id }

  let(:pool) {
    VmPool.create(
      size: 0, vm_size: "standard-2", boot_image: "img", location_id: Location::HETZNER_FSN1_ID,
      storage_size_gib: 86, storage_encrypted: true, storage_skip_sync: true,
      arch: "x64"
    )
  }

  describe ".assemble" do
    it "creates the entity and strand properly" do
      st = described_class.assemble(
        size: 3, vm_size: "standard-2", boot_image: "img", location_id: Location::HETZNER_FSN1_ID,
        storage_size_gib: 86, storage_encrypted: true,
        storage_skip_sync: false, arch: "x64"
      )
      pool = VmPool[st.id]
      expect(pool).not_to be_nil
      expect(pool.size).to eq(3)
      expect(pool.vm_size).to eq("standard-2")
      expect(pool.boot_image).to eq("img")
      expect(pool.location_id).to eq(Location::HETZNER_FSN1_ID)
      expect(pool.storage_size_gib).to eq(86)
      expect(pool.storage_encrypted).to be(true)
      expect(pool.storage_skip_sync).to be(false)
      expect(st.label).to eq("create_new_vm")
    end
  end

  describe "#create_new_vm" do
    it "creates a new vm and hops to wait" do
      expect(Config).to receive(:vm_pool_project_id).and_return(project_id).at_least(:once)
      expect { nx.create_new_vm }.to hop("wait")
      expect(pool.vms.count).to eq(1)
      vm = pool.vms.first
      expect(vm.unix_user).to eq("runneradmin")
      expect(vm.sshable.unix_user).to eq("runneradmin")
    end
  end

  describe "#wait" do
    before do
      create_vm_host(location_id: "6b9ef786-b842-8420-8c65-c25e3d4bdf3d", total_cores: 2, total_cpus: 4, used_cores: 0)
    end

    it "waits if nothing to do" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to create_new_vm if there are enough idle cores" do
      pool.update(size: 1)

      expect { nx.wait }.to hop("create_new_vm")
    end

    it "hops to create_new_vm if there are enough idle cores for the given arch" do
      pool.update(size: 1)
      create_vm(vm_host: VmHost.first, location_id: Location::GITHUB_RUNNERS_ID, boot_image: "github-ubuntu-2204", arch: "arm64")

      expect { nx.wait }.to hop("create_new_vm")
    end

    it "waits if there are not enough idle cores due to waiting github runners" do
      pool.update(size: 1)
      create_vm(vm_host: VmHost.first, location_id: Location::GITHUB_RUNNERS_ID, boot_image: "github-ubuntu-2204", arch: "x64", cores: 2, vcpus: 4, memory_gib: 8)

      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "increments vms' destroy semaphore and hops to wait_vms_destroy" do
      vm = Prog::Vm::Nexus.assemble("dummy key", project_id, pool_id: pool.id).subject
      ps = vm.private_subnets.first

      expect { nx.destroy }.to hop("wait_vms_destroy")
      expect(vm.destroy_set?).to be(true)
      expect(ps.destroy_set?).to be(true)
    end
  end

  describe "#wait_vms_destroy" do
    it "pops if vms are all destroyed" do
      expect(pool).to receive(:destroy)

      expect { nx.wait_vms_destroy }.to exit({"msg" => "pool destroyed"})
    end

    it "naps if there are still vms" do
      create_vm(pool_id: pool.id)

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
