# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { described_class.assemble("192.168.0.1") }
  let(:hetzner_ips) {
    [
      ["127.0.0.1", "127.0.0.1", false],
      ["30.30.30.32/29", "127.0.0.1", true],
      ["2a01:4f8:10a:128b::/64", "127.0.0.1", true]
    ].map {
      Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
    }
  }

  let(:vms) { [instance_double(Vm, mem_gib: 1), instance_double(Vm, mem_gib: 2)] }
  let(:vm_host) { instance_double(VmHost, vms: vms) }
  let(:sshable) { instance_double(Sshable) }

  before do
    allow(nx).to receive_messages(vm_host: vm_host, sshable: sshable)
  end

  describe ".assemble" do
    it "creates addresses properly for a regular host" do
      st = described_class.assemble("127.0.0.1")
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.subject.assigned_subnets.count).to eq(1)
      expect(st.subject.assigned_subnets.first.cidr.to_s).to eq("127.0.0.1/32")

      expect(st.subject.assigned_host_addresses.count).to eq(1)
      expect(st.subject.assigned_host_addresses.first.ip.to_s).to eq("127.0.0.1/32")
      expect(st.subject.provider).to be_nil
    end

    it "creates addresses properly for a hetzner host" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      expect(Hosting::Apis).to receive(:pull_data_center).and_return("fsn1-dc14")
      st = described_class.assemble("127.0.0.1", provider: "hetzner", hetzner_server_identifier: "1")
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.subject.assigned_subnets.count).to eq(3)
      expect(st.subject.assigned_subnets.map { _1.cidr.to_s }.sort).to eq(["127.0.0.1/32", "30.30.30.32/29", "2a01:4f8:10a:128b::/64"].sort)

      expect(st.subject.assigned_host_addresses.count).to eq(1)
      expect(st.subject.assigned_host_addresses.first.ip.to_s).to eq("127.0.0.1/32")
      expect(st.subject.provider).to eq("hetzner")
      expect(st.subject.data_center).to eq("fsn1-dc14")
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "pushes a bootstrap rhizome process" do
      expect(nx).to receive(:push).with(Prog::BootstrapRhizome, {"target_folder" => "host"}).and_call_original
      expect { nx.start }.to hop("start", "BootstrapRhizome")
    end

    it "hops once BootstrapRhizome has returned" do
      nx.strand.retval = {"msg" => "rhizome user bootstrapped and source installed"}
      expect { nx.start }.to hop("prep")
    end
  end

  describe "#prep" do
    it "starts a number of sub-programs" do
      expect(vm_host).to receive(:net6).and_return(NetAddr.parse_net("2a01:4f9:2b:35a::/64"))
      budded = []
      expect(nx).to receive(:bud) do
        budded << _1
      end.at_least(:once)

      expect { nx.prep }.to hop("wait_prep")

      expect(budded).to eq([
        Prog::Vm::PrepHost,
        Prog::LearnMemory,
        Prog::LearnArch,
        Prog::LearnCores,
        Prog::LearnStorage,
        Prog::LearnPci,
        Prog::InstallDnsmasq,
        Prog::SetupSysstat,
        Prog::SetupNftables
      ])
    end

    it "learns the network from the host if it is not set a-priori" do
      expect(vm_host).to receive(:net6).and_return(nil)
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
      expect(vm_host).to receive(:update).with(total_mem_gib: 1)
      expect(vm_host).to receive(:update).with(arch: "arm64")
      expect(vm_host).to receive(:update).with(total_cores: 4, total_cpus: 5, total_dies: 3, total_sockets: 2)
      expect(nx).to receive(:reap).and_return([
        instance_double(Strand, prog: "LearnMemory", exitval: {"mem_gib" => 1}),
        instance_double(Strand, prog: "LearnArch", exitval: {"arch" => "arm64"}),
        instance_double(Strand, prog: "LearnCores", exitval: {"total_sockets" => 2, "total_dies" => 3, "total_cores" => 4, "total_cpus" => 5}),
        instance_double(Strand, prog: "ArbitraryOtherProg")
      ])

      expect { nx.wait_prep }.to hop("setup_hugepages")
    end

    it "crashes if an expected field is not set for LearnMemory" do
      expect(nx).to receive(:reap).and_return([instance_double(Strand, prog: "LearnMemory", exitval: {})])
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"mem_gib\""
    end

    it "crashes if an expected field is not set for LearnCores" do
      expect(nx).to receive(:reap).and_return([instance_double(Strand, prog: "LearnCores", exitval: {})])
      expect { nx.wait_prep }.to raise_error KeyError, "key not found: \"total_cores\""
    end

    it "donates to children if they are not exited yet" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_prep }.to nap(1)
    end
  end

  describe "#setup_hugepages" do
    it "pushes the hugepage program" do
      expect { nx.setup_hugepages }.to hop("start", "SetupHugepages")
    end

    it "hops once SetupHugepages has returned" do
      nx.strand.retval = {"msg" => "hugepages installed"}
      expect { nx.setup_hugepages }.to hop("setup_spdk")
    end
  end

  describe "#setup_spdk" do
    it "pushes the spdk program" do
      expect(nx).to receive(:push).with(Prog::Storage::SetupSpdk,
        {
          "version" => Config.spdk_version,
          "start_service" => false,
          "allocation_weight" => 100
        }).and_call_original
      expect { nx.setup_spdk }.to hop("start", "Storage::SetupSpdk")
    end

    it "hops once SetupSpdk has returned" do
      nx.strand.retval = {"msg" => "SPDK was setup"}
      vmh = instance_double(VmHost)
      spdk_installation = SpdkInstallation.new(cpu_count: 4)
      allow(vmh).to receive_messages(
        spdk_installations: [spdk_installation],
        total_cores: 48,
        total_cpus: 96
      )
      allow(nx).to receive(:vm_host).and_return(vmh)
      expect(vmh).to receive(:update).with({used_cores: 2})
      expect { nx.setup_spdk }.to hop("download_boot_images")
    end
  end

  describe "#download_boot_images" do
    it "pushes the download boot image program" do
      expect(nx).to receive(:frame).and_return({"default_boot_images" => ["ubuntu-jammy", "github-ubuntu-2204"]})
      expect(nx).to receive(:bud).with(Prog::DownloadBootImage, {"image_name" => "ubuntu-jammy"})
      expect(nx).to receive(:bud).with(Prog::DownloadBootImage, {"image_name" => "github-ubuntu-2204"})
      expect { nx.download_boot_images }.to hop("wait_download_boot_images")
    end
  end

  describe "#wait_download_boot_images" do
    it "hops to prep_reboot if all tasks are done" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_download_boot_images }.to hop("prep_reboot")
    end

    it "donates its time if child strands are still running" do
      expect(nx).to receive(:reap).and_return([])
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_download_boot_images }.to nap(1)
    end
  end

  describe "#wait" do
    it "naps" do
      expect(vm_host).to receive(:values).and_return({location: "hetzner-hel1", arch: "x64", total_cores: 4})
      expect(vm_host).to receive(:vms_dataset).and_return(instance_double(Sequel::Dataset, count: 2))
      expect { nx.wait }.to nap(30)
    end

    it "hops to prep_reboot when needed" do
      expect(nx).to receive(:when_reboot_set?).and_yield
      expect { nx.wait }.to hop("prep_reboot")
    end

    it "hops to unavailable based on the host's available status" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      expect(vm_host).to receive(:values).and_return({location: "hetzner-hel1", arch: "x64", total_cores: 4})
      expect(vm_host).to receive(:vms_dataset).and_return(instance_double(Sequel::Dataset, count: 2))
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#unavailable" do
    it "creates a page if host is unavailable" do
      expect(vm_host).to receive(:ubid).and_return("vhxxxx").at_least(:once)
      expect(Prog::PageNexus).to receive(:assemble)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "resolves the page if host is available" do
      expect(vm_host).to receive(:ubid).and_return("vhxxxx").at_least(:once)
      expect(Prog::PageNexus).to receive(:assemble)
      pg = instance_double(Page)
      expect(pg).to receive(:incr_resolve)
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(pg)
      expect { nx.unavailable }.to hop("wait")
    end

    it "does not resolves the page if there is none" do
      expect(vm_host).to receive(:ubid).and_return("vhxxxx").at_least(:once)
      expect(Prog::PageNexus).to receive(:assemble)
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(nil)
      expect { nx.unavailable }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "updates allocation state and naps" do
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect(vm_host).to receive(:update).with(allocation_state: "draining")
      expect { nx.destroy }.to nap(5)
    end

    it "waits draining" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(Clog).to receive(:emit).with("Cannot destroy the vm host with active virtual machines, first clean them up").and_call_original
      expect { nx.destroy }.to nap(15)
    end

    it "deletes and exists" do
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect(vm_host).to receive(:vms).and_return([])
      expect(vm_host).to receive(:destroy)
      expect(sshable).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "vm host deleted"})
    end
  end

  describe "host reboot" do
    it "prep_reboot transitions to reboot" do
      expect(nx).to receive(:get_boot_id).and_return("xyz")
      expect(vm_host).to receive(:update).with(last_boot_id: "xyz")
      expect(vms).to all receive(:update).with(display_state: "rebooting")
      expect(nx).to receive(:decr_reboot)
      expect { nx.prep_reboot }.to hop("reboot")
    end

    it "reboot naps if reboot-host fails causes IOError" do
      expect(vm_host).to receive(:last_boot_id).and_return("xyz")
      expect(sshable).to receive(:cmd).with("sudo host/bin/reboot-host xyz").and_raise(IOError)

      expect { nx.reboot }.to nap(30)
    end

    it "reboot naps if reboot-host returns empty string" do
      expect(vm_host).to receive(:last_boot_id).and_return("xyz")
      expect(sshable).to receive(:cmd).with("sudo host/bin/reboot-host xyz").and_return ""

      expect { nx.reboot }.to nap(30)
    end

    it "reboot updates last_boot_id and hops to verify_spdk" do
      expect(vm_host).to receive(:last_boot_id).and_return("xyz")
      expect(sshable).to receive(:cmd).with("sudo host/bin/reboot-host xyz").and_return "pqr\n"
      expect(vm_host).to receive(:update).with(last_boot_id: "pqr")

      expect { nx.reboot }.to hop("verify_spdk")
    end

    it "verify_spdk hops to verify_hugepages if spdk started" do
      expect(vm_host).to receive(:spdk_installations).and_return([
        SpdkInstallation.new(version: "v1.0"),
        SpdkInstallation.new(version: "v3.0")
      ])
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk verify v1.0")
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk verify v3.0")
      expect { nx.verify_spdk }.to hop("verify_hugepages")
    end

    it "start_vms starts vms & becomes accepting & hops to wait if unprepared" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:allocation_state).and_return("unprepared")
      expect(vm_host).to receive(:update).with(allocation_state: "accepting")
      expect { nx.start_vms }.to hop("wait")
    end

    it "start_vms starts vms & hops to wait if accepting" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect { nx.start_vms }.to hop("wait")
    end

    it "start_vms starts vms & hops to wait if draining" do
      expect(vms).to all receive(:incr_start_after_host_reboot)
      expect(vm_host).to receive(:allocation_state).and_return("draining")
      expect { nx.start_vms }.to hop("wait")
    end

    it "can get boot id" do
      expect(sshable).to receive(:cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("xyz\n")
      expect(nx.get_boot_id).to eq("xyz")
    end
  end

  describe "#verify_hugepages" do
    it "fails if hugepagesize!=1G" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 2048 kB\n")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't set hugepage size to 1G"
    end

    it "fails if total hugepages couldn't be extracted" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo").and_return("Hugepagesize: 1048576 kB\n")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't extract total hugepage count"
    end

    it "fails if free hugepages couldn't be extracted" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Couldn't extract free hugepage count"
    end

    it "fails if not enough hugepages for VMs" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5\nHugePages_Free: 2")
      expect { nx.verify_hugepages }.to raise_error RuntimeError, "Not enough hugepages for VMs"
    end

    it "updates vm_host with hugepage stats and hops" do
      expect(sshable).to receive(:cmd).with("cat /proc/meminfo")
        .and_return("Hugepagesize: 1048576 kB\nHugePages_Total: 5\nHugePages_Free: 4")
      expect(vm_host).to receive(:update)
        .with(total_hugepages_1g: 5, used_hugepages_1g: 4)
      expect { nx.verify_hugepages }.to hop("start_vms")
    end
  end

  describe "#available?" do
    it "returns the available status" do
      expect(sshable).to receive(:cmd).and_return("true")
      expect(nx.available?).to be true

      expect(sshable).to receive(:cmd).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect(nx.available?).to be false
    end
  end
end
