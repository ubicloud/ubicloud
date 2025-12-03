# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Prog::Vm::PrepHost do
  subject(:ph) {
    described_class.new(Strand.new)
  }

  describe "#start" do
    it "prepare host" do
      sshable = Sshable.new
      vm_host = instance_double(VmHost, ubid: "vmhostubid")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/prep_host.rb #{vm_host.ubid} test")
      expect(ph).to receive(:sshable).and_return(sshable)
      expect(ph).to receive(:vm_host).and_return(vm_host)

      expect { ph.start }.to exit({"msg" => "host prepared"})
    end
  end
end
