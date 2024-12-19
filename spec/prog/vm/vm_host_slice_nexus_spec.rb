# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/vm/vm_host_slice_nexus"
require_relative "../../../prog/vm/host_nexus"

RSpec.describe Prog::Vm::VmHostSliceNexus do
  subject(:nx) { described_class.new(Strand.create(id: "b231a172-8f56-8b10-bbed-8916ea4e5c28", prog: "Prog::Vm::VmHostSliceNexus", label: "create")) }

  let(:vm_host_slice) {
    instance_double(
      VmHostSlice,
      id: "b231a172-8f56-8b10-bbed-8916ea4e5c28",
      name: "standard",
      type: "dedicated",
      allowed_cpus: "2-3",
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_gib: 4,
      used_memory_gib: 0
    )
  }

  let(:vm_host) {
    instance_double(
      VmHost,
      id: "b90b0af0-5d59-8b71-9b76-206a595e5e1a",
      sshable: sshable,
      allocation_state: "accepting",
      location: "hetzner-fsn1",
      total_mem_gib: 32,
      total_sockets: 1,
      total_cores: 4,
      total_cpus: 8,
      used_cores: 1,
      ndp_needed: false,
      total_hugepages_1g: 27,
      used_hugepages_1g: 2,
      last_boot_id: "cab237d5-c3bd-45e5-b50c-fc49f644809c",
      data_center: "FSN1-DC1",
      arch: "x64",
      total_dies: 1
    )
  }

  let(:sshable) { instance_double(Sshable) }

  before do
    allow(nx).to receive_messages(vm_host_slice: vm_host_slice)
    allow(vm_host_slice).to receive_messages(vm_host: vm_host)
  end

  describe ".assemble_with_host" do
    it "fails with an empty host" do
      expect { described_class.assemble_with_host("standard", nil, family: "standard", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Must provide a VmHost."
    end

    it "fails with an empty invalid vm_host_slice name" do
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil

      expect { described_class.assemble_with_host(nil, host, family: "standard", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Must provide slice name."
      expect { described_class.assemble_with_host("", host, family: "standard", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Must provide slice name."
      expect { described_class.assemble_with_host("user", host, family: "standard", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Slice name cannot be 'user' or 'system'."
      expect { described_class.assemble_with_host("system", host, family: "standard", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Slice name cannot be 'user' or 'system'."
      expect { described_class.assemble_with_host("invalid-name", host, family: "standard", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Slice name cannot contain a hyphen (-)."
    end

    it "fails with an empty family name" do
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil

      expect { described_class.assemble_with_host("test", host, family: nil, allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Must provide family name."
      expect { described_class.assemble_with_host("test", host, family: "", allowed_cpus: "", memory_gib: 0) }.to raise_error RuntimeError, "Must provide family name."
    end

    it "creates vm host slice" do
      # prepare the host for the test
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil
      host.update(total_cpus: 8, total_cores: 4)

      # run the assemble test
      st_rg = described_class.assemble_with_host("standard", host, family: "standard", allowed_cpus: "2-3", memory_gib: 4)
      rg = st_rg.subject
      expect(rg).not_to be_nil
      expect(rg.name).to eq("standard")
      expect(rg.allowed_cpus).to eq("2-3")
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
end
