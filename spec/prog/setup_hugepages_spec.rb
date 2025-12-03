# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupHugepages do
  subject(:sh) {
    described_class.new(Strand.new(prog: "SetupHugepages"))
  }

  describe "#start" do
    it "pops after installing hugepages" do
      vm_host = instance_double(VmHost)
      allow(vm_host).to receive(:total_mem_gib).and_return(64)
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with(/sudo sed.*default_hugepagesz=1G.*hugepagesz=1G.*hugepages=59.*grub/)
      expect(sshable).to receive(:_cmd).with("sudo update-grub")
      expect(sh).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(sh).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end
  end
end
