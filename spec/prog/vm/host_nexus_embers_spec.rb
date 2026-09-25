# frozen_string_literal: true

require_relative "../../model/spec_helper"

# The ember half of Prog::Vm::HostNexus: bringing a host up to run embers and
# nothing else.
RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(strand) }

  let(:vm_host) { create_ember_host }
  let(:strand) { Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "wait") }
  let(:sshable) { nx.sshable }

  before { strand }

  describe ".assemble" do
    it "records that the host is for embers" do
      st = described_class.assemble("127.0.0.2", accepts_embers: true, vhost_block_backend_version: "v0.5.1")
      expect(st.subject.accepts_embers).to be true
    end

    it "refuses a ubiblk embers cannot run on" do
      expect { described_class.assemble("127.0.0.2", accepts_embers: true, vhost_block_backend_version: "v0.4.2") }
        .to raise_error(RuntimeError, /newer ubiblk than v0.4.2/)
    end
  end

  describe "bring-up" do
    it "skips hugepages on an ember host" do
      st = Strand.create_with_id(create_ember_host, prog: "Vm::HostNexus", label: "wait_prep")
      expect { described_class.new(st).wait_prep }.to hop("setup_storage_backend")
    end

    it "prepares the slots" do
      expect(nx.vm_host.ember).to receive(:cmd_json).with("sudo host/bin/ember setup").and_return({"ok" => true})
      expect { nx.prep_embers }.to hop("learn_ember_signature")
    end

    it "learns the CPU signature" do
      expect(sshable).to receive(:_cmd).with("cat /proc/cpuinfo").and_return(<<~CPUINFO)
        vendor_id\t: AuthenticAMD
        cpu family\t: 25
        model\t\t: 97
        model name\t: AMD Ryzen 9 7950X3D
        stepping\t: 2
      CPUINFO
      expect { nx.learn_ember_signature }.to hop("start_vms")
      expect(vm_host.reload.cpu_signature).to eq("AuthenticAMD-25-97-2/#{Config.ember_ch_version}")
    end
  end

  # Slot namespaces, taps and sysctls do not survive a reboot, and an ember host
  # has no hugepages to verify.
  describe "after a reboot" do
    it "sets the slots up again" do
      expect(sshable).to receive(:available?).and_return(true)
      vm_host.update(last_boot_id: "xyz")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"
      expect { nx.reboot }.to hop("prep_embers")
    end

    it "does so after SPDK is verified, too" do
      SpdkInstallation.create(vm_host_id: vm_host.id, version: "v1.0", allocation_weight: 100)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-spdk verify v1.0")
      expect { nx.verify_spdk }.to hop("prep_embers")
    end
  end
end
