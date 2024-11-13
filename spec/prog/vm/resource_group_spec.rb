# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/vm/resource_group"
require_relative "../../../prog/vm/host_nexus"

RSpec.describe Prog::Vm::ResourceGroup do
  subject(:nx) { described_class.new(Strand.create(id: "b231a172-8f56-8b10-bbed-8916ea4e5c28", prog: "Prog::Vm::ResourceGroup", label: "create")) }

  let(:resource_group) {
    instance_double(
      ResourceGroup,
      id: "b231a172-8f56-8b10-bbed-8916ea4e5c28",
      name: "standard",
      type: "dedicated",
      allowed_cpus: "2-3",
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_1g: 4,
      used_memory_1g: 0
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
    allow(nx).to receive_messages(resource_group: resource_group)
    allow(resource_group).to receive_messages(vm_host: vm_host)
  end

  describe ".assemble_with_host" do
    it "fails with an empty host" do
      expect { described_class.assemble_with_host("standard", nil, allowed_cpus: "", memory_1g: 0) }.to raise_error RuntimeError, "Must provide a VmHost."
    end

    it "fails with an empty invalid resource_group name" do
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil

      expect { described_class.assemble_with_host(nil, host, allowed_cpus: "", memory_1g: 0) }.to raise_error RuntimeError, "Must provide resource group name."
      expect { described_class.assemble_with_host("", host, allowed_cpus: "", memory_1g: 0) }.to raise_error RuntimeError, "Must provide resource group name."
      expect { described_class.assemble_with_host("user", host, allowed_cpus: "", memory_1g: 0) }.to raise_error RuntimeError, "Resource group name cannot be 'user' or 'system'."
      expect { described_class.assemble_with_host("system", host, allowed_cpus: "", memory_1g: 0) }.to raise_error RuntimeError, "Resource group name cannot be 'user' or 'system'."
      expect { described_class.assemble_with_host("invalid-name", host, allowed_cpus: "", memory_1g: 0) }.to raise_error RuntimeError, "Resource group name cannot contain a hyphen (-)."
    end

    it "creates resource group" do
      # prepare the host for the test
      st_vh = Prog::Vm::HostNexus.assemble("1.2.3.4")
      host = st_vh.subject
      expect(host).not_to be_nil
      host.update(total_cpus: 8, total_cores: 4)

      # run the assemble test
      st_rg = described_class.assemble_with_host("standard", host, allowed_cpus: "2-3", memory_1g: 4)
      rg = st_rg.subject
      expect(rg).not_to be_nil
      expect(rg.name).to eq("standard")
      expect(rg.allowed_cpus).to eq("2-3")
      expect(rg.cores).to eq(1)
      expect(rg.total_cpu_percent).to eq(200)
      expect(rg.used_cpu_percent).to eq(0)
      expect(rg.total_memory_1g).to eq(4)
      expect(rg.used_memory_1g).to eq(0)
      expect(rg.allocation_state).to eq("unprepared")
      expect(rg.type).to eq("dedicated")
      expect(rg.id).to eq(st_rg.id)
      expect(rg.ubid).to eq(st_rg.ubid)
      expect(rg.ubid[..1] == "rg").to be true
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
    it "starts prep" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_standard").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo host/bin/setup-rg prep standard.slice \"2-3\"' prep_standard")
      expect(resource_group).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.prep }.to nap(1)
    end

    it "hops to wait" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check prep_standard").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean prep_standard")
      expect(resource_group).to receive(:update).with(allocation_state: "accepting")

      expect { nx.prep }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for 30 seconds" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      expect(resource_group).to receive(:destroy)
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-rg delete standard.slice")
      expect(resource_group).to receive(:update).with(allocation_state: "draining")
      expect(resource_group).to receive(:inhost_name).and_return("standard.slice")

      expect { nx.destroy }.to exit({"msg" => "resource_group destroyed"})
    end
  end
end
