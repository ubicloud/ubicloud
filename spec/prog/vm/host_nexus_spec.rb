# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new }
  let(:hetzner_ips) {
    [
      ["127.0.0.1", "127.0.0.1", false],
      ["30.30.30.32/29", "127.0.0.1", true],
      ["2a01:4f8:10a:128b::/64", "127.0.0.1", true]
    ].map {
      Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
    }
  }

  describe ".assemble" do
    it "creates addresses properly for a regular host" do
      st = described_class.assemble("127.0.0.1")
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.vm_host.assigned_subnets.count).to eq(1)
      expect(st.vm_host.assigned_subnets.first.cidr.to_s).to eq("127.0.0.1/32")

      expect(st.vm_host.assigned_host_addresses.count).to eq(1)
      expect(st.vm_host.assigned_host_addresses.first.ip.to_s).to eq("127.0.0.1/32")
      expect(st.vm_host.provider).to be_nil
    end

    it "creates addresses properly for a hetzner host" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      st = described_class.assemble("127.0.0.1", provider: "hetzner", hetzner_server_identifier: "1")
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.vm_host.assigned_subnets.count).to eq(3)
      expect(st.vm_host.assigned_subnets.map(&:cidr).map(&:to_s).sort).to eq(["127.0.0.1/32", "30.30.30.32/29", "2a01:4f8:10a:128b::/64"].sort)

      expect(st.vm_host.assigned_host_addresses.count).to eq(1)
      expect(st.vm_host.assigned_host_addresses.first.ip.to_s).to eq("127.0.0.1/32")
      expect(st.vm_host.provider).to eq("hetzner")
    end
  end

  describe "#start" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome)
      expect { nx.start }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(nx).to receive(:reap) }

    it "hops to prep if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_bootstrap_rhizome }.to hop("prep")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_bootstrap_rhizome }.to nap(0)
    end
  end

  describe "#prep" do
    it "starts a number of sub-programs" do
      nx.instance_variable_set(:@vm_host, instance_double(VmHost,
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64")))
      budded = []
      expect(nx).to receive(:bud) do
        budded << _1
      end.at_least(:once)

      expect { nx.prep }.to hop("wait_prep")

      expect(budded).to eq([
        Prog::Vm::PrepHost,
        Prog::LearnMemory,
        Prog::LearnCores,
        Prog::LearnStorage,
        Prog::InstallDnsmasq
      ])
    end

    it "learns the network from the host if it is not set a-priori" do
      nx.instance_variable_set(:@vm_host, instance_double(VmHost, net6: nil))

      budded_learn_network = false
      expect(nx).to receive(:bud) do
        budded_learn_network ||= (_1 == Prog::LearnNetwork)
      end.at_least(:once)

      expect { nx.prep }.to hop("wait_prep")

      expect(budded_learn_network).to be true
    end
  end

  describe "#wait_prep" do
    it "updates the vm_host record from the finished programs" do
      expect(nx).to receive(:leaf?).and_return(true)
      vmh = instance_double(VmHost)
      nx.instance_variable_set(:@vm_host, vmh)
      expect(vmh).to receive(:update).with(total_mem_gib: 1)
      expect(vmh).to receive(:update).with(total_cores: 4, total_cpus: 5, total_nodes: 3, total_sockets: 2)
      expect(vmh).to receive(:update).with(total_storage_gib: 300, available_storage_gib: 500)
      expect(nx).to receive(:reap).and_return([
        {prog: "LearnMemory", exitval: {"mem_gib" => 1}},
        {prog: "LearnCores", exitval: {"total_sockets" => 2, "total_nodes" => 3, "total_cores" => 4, "total_cpus" => 5}},
        {prog: "LearnStorage", exitval: {"total_storage_gib" => 300, "available_storage_gib" => 500}},
        {prog: "ArbitraryOtherProg"}
      ])

      expect { nx.wait_prep }.to hop("setup_hugepages")
    end

    it "crashes if an expected field is not set for LearnMemory" do
      expect(nx).to receive(:reap).and_return([{prog: "LearnMemory", exitval: {}}])
      expect { nx.wait_prep }.to raise_error RuntimeError, "BUG: mem_gib not set"
    end

    it "crashes if an expected field is not set for LearnCores" do
      expect(nx).to receive(:reap).and_return([{prog: "LearnCores", exitval: {}}])
      expect { nx.wait_prep }.to raise_error RuntimeError, "BUG: one of the LearnCores fields is not set"
    end

    it "crashes if an expected field is not set for LearnStorage" do
      expect(nx).to receive(:reap).and_return([{prog: "LearnStorage", exitval: {}}])
      expect { nx.wait_prep }.to raise_error RuntimeError, "BUG: one of the LearnStorage fields is not set"
    end

    it "donates to children if they are not exited yet" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_prep }.to nap(0)
    end
  end

  describe "#setup_hugepages" do
    it "buds the hugepage program" do
      expect(nx).to receive(:bud).with(Prog::SetupHugepages)
      expect { nx.setup_hugepages }.to hop("wait_setup_hugepages")
    end
  end

  describe "#wait_setup_hugepages" do
    it "enters the setup_spdk state" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return true
      vmh = instance_double(VmHost)
      nx.instance_variable_set(:@vm_host, vmh)

      expect { nx.wait_setup_hugepages }.to hop("setup_spdk")
    end

    it "donates its time if child strands are still running" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_setup_hugepages }.to nap(0)
    end
  end

  describe "#setup_spdk" do
    it "buds the spdk program" do
      expect(nx).to receive(:bud).with(Prog::SetupSpdk)
      expect { nx.setup_spdk }.to hop("wait_setup_spdk")
    end
  end

  describe "#wait_setup_spdk" do
    it "enters the wait state and toggled the VM acceptance state if all tasks are done" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return true
      vmh = instance_double(VmHost)
      nx.instance_variable_set(:@vm_host, vmh)

      expect(vmh).to receive(:update).with(allocation_state: "accepting")

      expect { nx.wait_setup_spdk }.to hop("wait")
    end

    it "donates its time if child strands are still running" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_setup_spdk }.to nap(0)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to reboot when needed" do
      expect(nx).to receive(:when_reboot_set?).and_yield
      expect { nx.wait }.to hop("reboot")
    end
  end

  describe "host reboot" do
    let(:vms) { [instance_double(Vm), instance_double(Vm)] }
    let(:vm_host) {
      host = instance_double(VmHost)
      allow(host).to receive(:vms).and_return(vms)
      host
    }
    let(:sshable) { instance_double(Sshable) }

    before do
      allow(nx).to receive_messages(vm_host: vm_host, sshable: sshable)
    end

    it "reboot transitions to wait_reboot" do
      expect(nx).to receive(:get_boot_id).and_return("xyz")
      expect(vm_host).to receive(:update).with(last_boot_id: "xyz")
      expect(vms).to all receive(:update).with(display_state: "rebooting")
      expect(sshable).to receive(:cmd).with("sudo systemctl reboot")
      expect(nx).to receive(:hop).with(:wait_reboot)
      expect(nx).to receive(:decr_reboot)
      nx.reboot
    end

    it "wait_reboot naps if ssh fails" do
      expect(sshable).to receive(:cmd).with("echo 1").and_raise("not connected")
      expect { nx.wait_reboot }.to nap(15)
    end

    it "wait_reboot transitions to verify_boot_id_changed if ssh succeeds" do
      expect(sshable).to receive(:cmd).with("echo 1").and_return("1")
      expect { nx.wait_reboot }.to hop("verify_boot_id_changed")
    end

    it "verify_boot_id_changed hops to start_vms if successful" do
      expect(nx).to receive(:get_boot_id).and_return("xyz")
      expect(vm_host).to receive(:last_boot_id).and_return("abc")
      expect(vm_host).to receive(:update).with(last_boot_id: "xyz")
      expect(nx).to receive(:hop).with(:start_vms)
      nx.verify_boot_id_changed
    end

    it "verify_boot_id_changed fails if boot_id hasn't changed" do
      expect(nx).to receive(:get_boot_id).and_return("abc")
      expect(vm_host).to receive(:last_boot_id).and_return("abc")
      expect { nx.verify_boot_id_changed }.to raise_error RuntimeError, "reboot failed"
    end

    it "start_vms starts vms & hops to wait" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(nx).to receive(:hop).with(:wait)
      nx.start_vms
    end

    it "can get boot id" do
      expect(sshable).to receive(:cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("xyz\n")
      expect(nx.get_boot_id).to eq("xyz")
    end
  end
end
