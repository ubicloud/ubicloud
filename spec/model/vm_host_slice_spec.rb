# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VmHostSlice do
  subject(:vm_host_slice) do
    described_class.create_with_id(
      vm_host_id: vm_host.id,
      name: "standard",
      family: "standard",
      is_shared: false,
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_gib: 4,
      used_memory_gib: 0
    )
  end

  let(:sshable) {
    Sshable.create_with_id
  }

  let(:vm_host) {
    sshable = Sshable.create_with_id
    VmHost.create(
      location: "x",
      total_cores: 4,
      total_cpus: 8,
      used_cores: 1
    ) { _1.id = sshable.id }
  }

  before do
    allow(vm_host_slice).to receive(:vm_host).and_return(vm_host)
    allow(vm_host).to receive(:sshable).and_return(sshable)
    (0..15).each { |i|
      VmHostCpu.create(
        vm_host_id: vm_host.id,
        cpu_number: i,
        spdk: i < 2,
        vm_host_slice_id: (i == 2 || i == 3) ? vm_host_slice.id : nil
      )
    }
  end

  describe "#allowed_cpus_cgroup" do
    it "returns the correct allowed_cpus_cgroup" do
      expect(vm_host_slice.allowed_cpus_cgroup).to eq("2-3")
    end

    it "returns the correct allowed_cpus_group if we have multiple disjoint cpus" do
      VmHostCpu.where(
        vm_host_id: vm_host.id,
        cpu_number: [2, 3, 6, 11, 12, 13]
      ).update(vm_host_slice_id: vm_host_slice.id)
      expect(vm_host_slice.allowed_cpus_cgroup).to eq("2-3,6,11-13")
    end
  end

  describe "#set_allowed_cpus" do
    it "sets the allowed cpus when cpu/core ratio is 2" do
      vm_host.update(total_cpus: 8, total_cores: 4)
      vm_host_slice.set_allowed_cpus([4, 5])
      expect(vm_host_slice.cores).to eq(1)
      expect(vm_host_slice.total_cpu_percent).to eq(200)
    end

    it "sets the allowed cpus when cpu/core ratio is 1" do
      vm_host.update(total_cpus: 8, total_cores: 8)
      vm_host_slice.set_allowed_cpus([4, 5, 6, 7])
      expect(vm_host_slice.cores).to eq(4)
      expect(vm_host_slice.total_cpu_percent).to eq(400)
    end

    it "raises an error if not enough cpus are available" do
      expect {
        vm_host_slice.set_allowed_cpus([2, 3, 4])
      }.to raise_error("Not enough CPUs available.")
    end
  end
end
