# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::VmHostSlices do
  subject(:vm_host_slices) {
    described_class.new(Strand.new(prog: "Test::VmHostSlices", label: "start"))
  }

  # rubocop:disable RSpec/IndexedLet
  let(:slice1) {
    instance_double(VmHostSlice,
      id: "ff7539aa-e3e3-48d6-8a77-6e77cead900d",
      allowed_cpus_cgroup: "2-3",
      is_shared: false,
      cpus: [instance_double(VmHostCpu, cpu_number: 2), instance_double(VmHostCpu, cpu_number: 3)])
  }

  let(:slice2) {
    instance_double(VmHostSlice,
      id: "115dd7bb-3081-4403-8b74-eda45e0e2fb1",
      allowed_cpus_cgroup: "4-5",
      is_shared: false,
      cpus: [instance_double(VmHostCpu, cpu_number: 4), instance_double(VmHostCpu, cpu_number: 5)])
  }

  let(:slice3) {
    instance_double(VmHostSlice,
      id: "da2b7a0e-be79-440f-8797-54e367a4aabd",
      allowed_cpus_cgroup: "6-7",
      is_shared: false,
      cpus: [instance_double(VmHostCpu, cpu_number: 6), instance_double(VmHostCpu, cpu_number: 7)])
  }
  # rubocop:enable RSpec/IndexedLet

  let(:slice2_overlap) {
    instance_double(VmHostSlice,
      id: "7f509282-6598-4fee-8a55-481f9fd6add4",
      allowed_cpus_cgroup: "3-4",
      is_shared: false,
      cpus: [instance_double(VmHostCpu, cpu_number: 3), instance_double(VmHostCpu, cpu_number: 4)])
  }

  let(:slice_burstable) {
    instance_double(VmHostSlice,
      id: "0137d721-ab5e-4551-bdb5-2163b61aa515",
      allowed_cpus_cgroup: "8-9",
      is_shared: true,
      cpus: [instance_double(VmHostCpu, cpu_number: 8), instance_double(VmHostCpu, cpu_number: 9)])
  }

  let(:vm_host) {
    instance_double(VmHost,
      sshable: create_mock_sshable(start_fresh_session: instance_double(Net::SSH::Connection::Session, shutdown!: nil, close: nil)))
  }

  let(:strand) {
    instance_double(Strand)
  }

  before do
    allow(vm_host_slices).to receive_messages(strand: strand)
  end

  describe "#start" do
    it "hops to verify_separation" do
      expect { vm_host_slices.start }.to hop("verify_separation")
    end
  end

  describe "#verify_separation" do
    it "fails the test if the slices are the same" do
      allow(vm_host_slices).to receive_messages(slices: [slice1, slice1, slice2])
      expect(strand).to receive(:update).with(exitval: {msg: /Two Vm instances placed in the same slice;/})

      expect { vm_host_slices.verify_separation }.to hop("failed")
    end

    it "fails the test if the slices are on the same CPUs" do
      allow(vm_host_slices).to receive_messages(slices: [slice2, slice3, slice2_overlap])
      expect(strand).to receive(:update).with(exitval: {msg: /Two Vm instances are sharing at least one cpu;/})

      expect { vm_host_slices.verify_separation }.to hop("failed")
    end

    it "handles burstable slices" do
      allow(vm_host_slices).to receive_messages(slices: [slice2, slice_burstable, slice3, slice_burstable])
      expect { vm_host_slices.verify_separation }.to hop("verify_on_host")
    end

    it "hops to verify_on_host" do
      allow(vm_host_slices).to receive_messages(slices: [slice1, slice2, slice3])
      expect { vm_host_slices.verify_separation }.to hop("verify_on_host")
    end
  end

  describe "#verify_on_host" do
    before do
      allow(vm_host_slices).to receive_messages(slices: [slice1, slice2, slice3])

      sshable = Sshable.new
      session = instance_double(Net::SSH::Transport::Session)
      expect(vm_host).to receive_messages(sshable: sshable)
      expect(sshable).to receive(:start_fresh_session).and_yield(session).exactly(3).times

      [slice1, slice2, slice3].each do |slice|
        expect(slice).to receive(:vm_host).and_return(vm_host)
        expect(slice).to receive(:up?).with(session).and_return(true) unless slice == slice3
      end
    end

    it "fails the test if the slice is not setup correctly" do
      expect(slice3).to receive(:up?).and_return(false)
      expect(strand).to receive(:update).with(exitval: {msg: "Slice #{slice3.id} is not setup correctly"})

      expect { vm_host_slices.verify_on_host }.to hop("failed")
    end

    it "hops to finish" do
      expect(slice3).to receive(:up?).and_return(true)
      expect { vm_host_slices.verify_on_host }.to hop("finish")
    end
  end

  describe "#finish" do
    it "pops 'Verified VM Host Slices!'" do
      expect(vm_host_slices).to receive(:pop).with("Verified VM Host Slices!")
      vm_host_slices.finish
    end
  end

  describe "#failed" do
    it "naps for 15 seconds" do
      expect { vm_host_slices.failed }.to nap(15)
    end
  end

  describe "slices access method" do
    it "returns slices" do
      expect(vm_host_slices).to receive(:frame).and_return({"slices" => [slice1.id, slice2.id, slice3.id]})

      [slice1, slice2, slice3].each do |slice|
        expect(VmHostSlice).to receive(:[]).with(slice.id).and_return(slice)
      end

      expect(vm_host_slices.slices).to eq([slice1, slice2, slice3])
    end
  end
end
