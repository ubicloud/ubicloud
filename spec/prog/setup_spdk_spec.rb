# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupSpdk do
  subject(:ss) {
    described_class.new(Strand.new(prog: "SetupSpdk",
      stack: [{sshable_id: "bogus"}]))
  }

  describe "#start" do
    it "transitions to start_service" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo bin/setup-spdk")
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:total_hugepages_1g).and_return(10)
      expect(vm_host).to receive(:used_hugepages_1g).and_return(0)
      expect(ss).to receive(:sshable).and_return(sshable)
      expect(ss).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect { ss.start }.to hop("start_service")
    end

    it "fails if not enough hugepages" do
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:total_hugepages_1g).and_return(10)
      expect(vm_host).to receive(:used_hugepages_1g).and_return(10)
      expect(ss).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect { ss.start }.to raise_error RuntimeError, "Not enough hugepages"
    end
  end

  describe "#start_service" do
    it "exits, reducing number of hugepages" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo systemctl start spdk")
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:used_hugepages_1g).and_return(0)
      expect(vm_host).to receive(:update).with(used_hugepages_1g: 1)
      expect(ss).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(ss).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect(ss).to receive(:pop).with("SPDK was setup")
      ss.start_service
    end
  end
end
