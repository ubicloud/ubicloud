# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/vm/resource_group"

RSpec.describe Prog::Vm::ResourceGroup do
  subject(:st) { described_class.new(Strand.create(id: "b231a172-8f56-8b10-bbed-8916ea4e5c28", prog: "Prog::Vm::ResourceGroup", label: "create")) }

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

  before do
    allow(st).to receive_messages(resource_group: resource_group)
  end

  describe ".assemble" do
    it "creates resource group" do
      st_rg = Prog::Vm::ResourceGroup.assemble("standard", allowed_cpus: "2-3", cores: 1, memory_1g: 4)
      rg = st_rg.subject
      expect(rg).not_to be_nil
      expect(rg.name).to eq("standard")
      expect(rg.allowed_cpus).to eq("2-3")
      expect(rg.cores).to eq(1)
      expect(rg.total_cpu_percent).to eq(200)
      expect(rg.used_cpu_percent).to eq(0)
      expect(rg.total_memory_1g).to eq(4)
      expect(rg.used_memory_1g).to eq(0)
      expect(rg.vm_host).to be_nil
      expect(rg.allocation_state).to eq("unprepared")
      expect(rg.type).to eq("dedicated")
      expect(rg.id).to eq(st_rg.id)
      expect(rg.ubid).to eq(st_rg.ubid)
      expect(rg.ubid[..1] == "rg").to be true
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(st).to receive(:when_destroy_set?).and_yield
      expect { st.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(st).to receive(:when_destroy_set?).and_yield
      expect(st.strand).to receive(:label).and_return("destroy")
      expect { st.before_run }.not_to hop("destroy")
    end
  end

  describe "#create" do
    it "hops to wait" do
      expect { st.create }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for 30 seconds" do
      expect { st.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      expect(resource_group).to receive(:destroy)
      expect(resource_group).to receive(:update).with(allocation_state: "draining")

      expect { st.destroy }.to exit({"msg" => "resource_group destroyed"})
    end
  end
end
