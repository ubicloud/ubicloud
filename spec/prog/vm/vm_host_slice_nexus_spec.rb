# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/vm/vm_host_slice_nexus"
require_relative "../../../prog/vm/host_nexus"

RSpec.describe Prog::Vm::VmHostSliceNexus do
  subject(:nx) { described_class.new(Strand.create(id: "b231a172-8f56-8b10-bbed-8916ea4e5c28", prog: "Prog::Vm::VmHostSliceNexus", label: "create")) }

  let(:sshable) {
    Sshable.create_with_id
  }

  let(:vm_host) {
    VmHost.create(
      location: "x",
      total_cores: 4,
      used_cores: 1
    ) { _1.id = sshable.id }
  }

  let(:vm_host_slice) {
    VmHostSlice.create_with_id(
      vm_host_id: vm_host.id,
      name: "standard",
      type: "dedicated",
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_gib: 4,
      used_memory_gib: 0
    )
  }

  before do
    allow(nx).to receive_messages(vm_host_slice: vm_host_slice)
    allow(vm_host_slice).to receive(:vm_host).and_return(vm_host)
    allow(vm_host).to receive(:sshable).and_return(sshable)
    (0..15).each { |i|
      VmHostCpu.create(
        spdk: i < 2,
        vm_host_slice_id: (i == 2 || i == 3) ? vm_host_slice.id : nil
      ) {
        _1.vm_host_id = vm_host.id
        _1.cpu_number = i
      }
    }
  end

  describe ".assemble_with_host" do
    it "fails with an empty host" do
      expect { described_class.assemble_with_host("standard", nil, family: "standard", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Must provide a VmHost."
    end

    it "fails with an empty invalid vm_host_slice name" do
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil

      expect { described_class.assemble_with_host(nil, host, family: "standard", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Must provide slice name."
      expect { described_class.assemble_with_host("", host, family: "standard", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Must provide slice name."
      expect { described_class.assemble_with_host("user", host, family: "standard", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Slice name cannot be 'user' or 'system'."
      expect { described_class.assemble_with_host("system", host, family: "standard", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Slice name cannot be 'user' or 'system'."
      expect { described_class.assemble_with_host("invalid-name", host, family: "standard", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Slice name cannot contain a hyphen (-)."
    end

    it "fails with an empty family name" do
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil

      expect { described_class.assemble_with_host("test", host, family: nil, allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Must provide family name."
      expect { described_class.assemble_with_host("test", host, family: "", allowed_cpus: [], memory_gib: 0) }.to raise_error RuntimeError, "Must provide family name."
    end

    it "creates vm host slice" do
      # prepare the host for the test
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil
      host.update(total_cpus: 8, total_cores: 4)

      (0..15).each { |i|
        VmHostCpu.create(vm_host_id: host.id, cpu_number: i, spdk: i < 2)
      }

      # run the assemble test
      st_rg = described_class.assemble_with_host("standard", host, family: "standard", allowed_cpus: [2, 3], memory_gib: 4)
      rg = st_rg.subject
      expect(rg).not_to be_nil
      expect(rg.name).to eq("standard")
      expect(rg.allowed_cpus_cgroup).to eq("2-3")
      expect(rg.cores).to eq(1)
      expect(rg.total_cpu_percent).to eq(200)
      expect(rg.used_cpu_percent).to eq(0)
      expect(rg.total_memory_gib).to eq(4)
      expect(rg.used_memory_gib).to eq(0)
      expect(rg.enabled).to be(false)
      expect(rg.type).to eq("dedicated")
      expect(rg.id).to eq(st_rg.id)
      expect(rg.ubid).to eq(st_rg.ubid)
      expect(rg.ubid[..1] == "vs").to be true
      expect(rg.vm_host).not_to be_nil
      expect(rg.vm_host.id).to eq(host.id)
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

  describe "#prep" do
    it "starts prep on NotStarted" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_standard").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo host/bin/setup-slice prep standard.slice \"2-3\"' prep_standard")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.prep }.to nap(1)
    end

    it "starts prep on Failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_standard").and_return("Failed")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo host/bin/setup-slice prep standard.slice \"2-3\"' prep_standard")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.prep }.to nap(1)
    end

    it "hops to wait" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_standard").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean prep_standard")
      expect(vm_host_slice).to receive(:update).with(enabled: true)

      expect { nx.prep }.to hop("wait")
    end

    it "do nothing on random result" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_standard").and_return("foobar")

      expect { nx.prep }.to nap(1)
    end
  end

  describe "#wait" do
    it "naps for 30 seconds" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to start_after_host_reboot when signaled" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect(nx).to receive(:register_deadline).with(:wait, 5 * 60)
      expect { nx.wait }.to hop("start_after_host_reboot")
    end

    it "hops to unavailable based on the slice's available status" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_raise Sshable::SshError.new("ssh failed", "", "", nil, nil)
      expect { nx.wait }.to hop("unavailable")

      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      expect(vm_host_slice).to receive(:destroy)
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-slice delete standard.slice")
      expect(vm_host_slice).to receive(:update).with(enabled: false)
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.destroy }.to exit({"msg" => "vm_host_slice destroyed"})
    end
  end

  describe "#start_after_host_reboot" do
    it "starts slice on the host and hops to wait" do
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-slice recreate-unpersisted standard.slice")
      expect(vm_host_slice).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.start_after_host_reboot }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to start_after_host_reboot when needed" do
      expect(nx).to receive(:when_start_after_host_reboot_set?).and_yield
      expect(nx).to receive(:incr_checkup)
      expect { nx.unavailable }.to hop("start_after_host_reboot")
    end

    it "creates a page if vm is unavailable" do
      expect(Prog::PageNexus).to receive(:assemble)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "resolves the page if vm is available" do
      pg = instance_double(Page)
      expect(pg).to receive(:incr_resolve)
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(pg)
      expect { nx.unavailable }.to hop("wait")
    end

    it "does not resolves the page if there is none" do
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(nil)
      expect { nx.unavailable }.to hop("wait")
    end
  end

  describe "#available?" do
    it "returns the available status" do
      expect(sshable).to receive(:cmd).with("systemctl is-active standard.slice").and_return("active\nactive\n").once
      expect(sshable).to receive(:cmd).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.effective").and_return("2-3\n").once
      expect(sshable).to receive(:cmd).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.partition").and_return("root\n").once

      expect(nx.available?).to be true
    end

    it "fails on the incorrect partition status" do
      expect(sshable).to receive(:cmd).with("systemctl is-active standard.slice").and_return("active\nactive\n").once
      expect(sshable).to receive(:cmd).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.effective").and_return("2-3\n").once
      expect(sshable).to receive(:cmd).with("cat /sys/fs/cgroup/standard.slice/cpuset.cpus.partition").and_return("member\n").once

      expect(nx.available?).to be false
    end
  end
end
