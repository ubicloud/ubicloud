# frozen_string_literal: true

require "bitarray"
require_relative "../spec_helper"

RSpec.describe VmHostSlice do
  subject(:vm_host_slice) do
    described_class.new(
      name: "standard",
      type: "dedicated",
      allowed_cpus: "2-3",
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_1g: 4,
      used_memory_1g: 0
      ) { _1.id = "b231a172-8f56-8b10-bbed-8916ea4e5c28" }
  end 

  let(:vm_host) {
    instance_double(
      VmHost,
      id: "b90b0af0-5d59-8b71-9b76-206a595e5e1a",
      sshable: sshable,
      allocation_state: "accepting",
      location: "hetzner-fsn1",
      total_mem_gib: 32,
      total_sockets: 1,
      total_cores: 4,
      total_cpus: 8,
      used_cores: 1,
      ndp_needed: false,
      total_hugepages_1g: 27,
      used_hugepages_1g: 2,
      last_boot_id: "cab237d5-c3bd-45e5-b50c-fc49f644809c",
      data_center: "FSN1-DC1",
      arch: "x64",
      total_dies: 1
    )
  }

  let(:sshable) { instance_double(Sshable) }

  describe "#inhost_name" do
    it "returns the correct inhost_name" do
      expect(vm_host_slice.inhost_name).to eq("standard.slice")
    end
  end

  describe "#to_cpu_bitmask" do
    it "returns the correct bitmask" do
      expect(vm_host_slice.to_cpu_bitmask.to_s).to eq("0011")
    end

    it "resizes the bitmask to the number of cpus on the host" do
      allow(vm_host_slice).to receive_messages(vm_host: vm_host)
      expect(vm_host_slice.to_cpu_bitmask.to_s).to eq("00110000")
    end
  end

  describe "#from_cpu_bitmask" do
    it "converts a cpu bitmask to a correct allowed cpu set" do
      allow(vm_host_slice).to receive_messages(vm_host: vm_host)

      cpu_array = BitArray.new(8)
      cpu_array[0] = 1
      cpu_array[1] = 1
      cpu_array[6] = 1
      cpu_array[7] = 1
      vm_host_slice.from_cpu_bitmask(cpu_array)
      expect(vm_host_slice.allowed_cpus).to eq("0-1,6-7")
      expect(vm_host_slice.cores).to eq(2)
      expect(vm_host_slice.total_cpu_percent).to eq(400)
    end

    it "fails on empty bitmask" do
      bitmask = BitArray.new(16)
      expect{vm_host_slice.from_cpu_bitmask(bitmask)}.to raise_error RuntimeError, "Bitmask does not set any cpuset."
    end
  end

  describe "#cpuset_to_bitmask_and_back" do
    it "converts disjoined cpu ranges" do
      bitmask = VmHostSlice.cpuset_to_bitmask("2-3,6-7")
      expect(VmHostSlice.bitmask_to_cpuset(bitmask)).to eq("2-3,6-7")
    end

    it "handles nil or empty cpuset" do
      expect{ VmHostSlice.cpuset_to_bitmask(nil) }.to raise_error RuntimeError, "Cpuset cannot be empty."
      expect{ VmHostSlice.cpuset_to_bitmask("") }.to raise_error RuntimeError, "Cpuset cannot be empty."
    end

    it "handles invalid cpuset" do
      expect{ VmHostSlice.cpuset_to_bitmask("1234 abcd") }.to raise_error RuntimeError, "Cpuset can only contains numbers, comma (,) , and hypen (-)."
      expect{ VmHostSlice.cpuset_to_bitmask("1234-234%") }.to raise_error RuntimeError, "Cpuset can only contains numbers, comma (,) , and hypen (-)."
      expect{ VmHostSlice.cpuset_to_bitmask("1234-234-456") }.to raise_error RuntimeError, "Unexpected list of cpus in the cpuset."
    end

    it "handles single cpu" do
      bitmask = VmHostSlice.cpuset_to_bitmask("2-3,7")
      expect(VmHostSlice.bitmask_to_cpuset(bitmask)).to eq("2-3,7")

      bitmask = VmHostSlice.cpuset_to_bitmask("7")
      expect(VmHostSlice.bitmask_to_cpuset(bitmask)).to eq("7")

      bitmask = VmHostSlice.cpuset_to_bitmask("7-7")
      expect(VmHostSlice.bitmask_to_cpuset(bitmask)).to eq("7")
    end

    it "handles incorrect cpu ranges" do
      expect{ VmHostSlice.cpuset_to_bitmask("7-4") }.to raise_error RuntimeError, "Invalid list of cpus in the cpuset."
    end

    it "handles inverted order" do
      bitmask = VmHostSlice.cpuset_to_bitmask("6-7,2-3")
      expect(VmHostSlice.bitmask_to_cpuset(bitmask)).to eq("2-3,6-7")
    end

    it "handles all-zeros bitmask" do
      bitmask = BitArray.new(8)
      expect(VmHostSlice.bitmask_to_cpuset(bitmask)).to eq("")
    end
  end
end
