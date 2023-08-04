# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupHugepages do
  subject(:sh) {
    described_class.new(Strand.new(prog: "SetupHugepages",
      stack: [{sshable_id: "bogus"}]))
  }

  describe "#start" do
    it "pops after installing hugepages" do
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:total_mem_gib).and_return(64)
      expect(vm_host).to receive(:total_cores).and_return(4).at_least(:once)
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with(/sudo sed.*default_hugepagesz=1G.*hugepagesz=1G.*hugepages=49.*grub/)
      expect(sshable).to receive(:cmd).with("sudo update-grub")
      expect(sh).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(sh).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect(sh).to receive(:pop).with("hugepages installed")
      sh.start
    end
  end
end
