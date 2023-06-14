# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupHugepages do
  subject(:sh) {
    described_class.new(Strand.new(prog: "SetupHugepages",
      stack: [{sshable_id: "bogus"}]))
  }

  describe "#start" do
    it "transitions to wait_reboot" do
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:total_mem_gib).and_return(64)
      expect(vm_host).to receive(:total_cores).and_return(4).at_least(:once)
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with(/sudo sed.*default_hugepagesz=1G.*hugepagesz=1G.*hugepages=49.*grub/)
      expect(sshable).to receive(:cmd).with("sudo update-grub")
      expect(sshable).to receive(:cmd).with("sudo reboot")
      expect(sh).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(sh).to receive(:vm_host).and_return(vm_host).at_least(:once)
      expect(sh).to receive(:hop).with(:wait_reboot)
      sh.start
    end
  end

  describe "#wait_reboot" do
    it "naps if ssh fails" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("echo 1").and_raise("not connected")
      expect(sh).to receive(:sshable).and_return(sshable)
      expect { sh.wait_reboot }.to raise_error Prog::Base::Nap
    end

    it "transitions to check_hugepages if ssh succeeds" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("echo 1").and_return("1")
      expect(sh).to receive(:sshable).and_return(sshable)
      expect { sh.wait_reboot }.to raise_error(Prog::Base::Hop) do
        expect(_1.new_label).to eq("check_hugepages")
      end
    end
  end

  describe "#check_hugepages" do
    it "fails if hugepagesize!=1G" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 2048 kB\n")
      expect(sh).to receive(:sshable).and_return(sshable)
      expect { sh.check_hugepages }.to raise_error RuntimeError, "Couldn't set hugepage size to 1G"
    end

    it "fails if total hugepages couldn't be extracted" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 1048576 kB\n")
      expect(sh).to receive(:sshable).and_return(sshable)
      expect { sh.check_hugepages }.to raise_error RuntimeError, "Couldn't extract total hugepage count"
    end

    it "fails if free hugepages couldn't be extracted" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5")
      expect(sh).to receive(:sshable).and_return(sshable)
      expect { sh.check_hugepages }.to raise_error RuntimeError, "Couldn't extract free hugepage count"
    end

    it "updates vm_host with hugepage stats and pops" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5\nHugePages_Free: 4")
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:update)
        .with(total_hugepages_1g: 5, used_hugepages_1g: 1)
      expect(sh).to receive(:sshable).and_return(sshable)
      expect(sh).to receive(:vm_host).and_return(vm_host)
      expect(sh).to receive(:pop).with("hugepages installed")
      sh.check_hugepages
    end
  end
end
