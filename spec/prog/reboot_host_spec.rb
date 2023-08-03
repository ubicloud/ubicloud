# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RebootHost do
  subject(:rh) {
    described_class.new(Strand.new(prog: "RebootHost",
      stack: [{sshable_id: "bogus"}]))
  }

  let(:vms) { [instance_double(Vm), instance_double(Vm)] }
  let(:vm_host) {
    host = instance_double(VmHost)
    allow(host).to receive(:vms).and_return(vms)
    host
  }
  let(:sshable) { instance_double(Sshable) }

  before do
    allow(rh).to receive_messages(vm_host: vm_host, sshable: sshable)
  end

  describe "#start" do
    it "transitions to wait_reboot" do
      expect(vms).to all receive(:update).with(display_state: "rebooting host")
      expect(sshable).to receive(:cmd).with("sudo reboot")
      expect(rh).to receive(:hop).with(:wait_reboot)
      rh.start
    end
  end

  describe "#wait_reboot" do
    it "naps if ssh fails" do
      expect(sshable).to receive(:cmd).with("echo 1").and_raise("not connected")
      expect { rh.wait_reboot }.to nap(15)
    end

    it "transitions to start_vms if ssh succeeds" do
      expect(sshable).to receive(:cmd).with("echo 1").and_return("1")
      expect { rh.wait_reboot }.to hop("start_vms")
    end
  end

  describe "#start_vms" do
    it "starts vms & pops" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(rh).to receive(:pop).with("host rebooted")
      rh.start_vms
    end
  end
end
