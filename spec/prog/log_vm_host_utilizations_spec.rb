# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LogVmHostUtilizations do
  subject(:lvmhu) { described_class.new(Strand.new(prog: "LogVmHostUtilizations")) }

  describe "#wait" do
    it "logs vm host utilizations every minute" do
      [
        ["hetzner-fsn1", "x64", "standard", "accepting", 3, 10, 20, 80],
        ["hetzner-fsn1", "x64", "standard", "draining", 5, 20, 50, 150],
        ["hetzner-fsn1", "arm64", "standard", "accepting", 10, 80, 30, 200],
        ["hetzner-hel1", "x64", "standard", "accepting", 2, 10, 20, 100],
        ["hetzner-hel1", "x64", "standard", "accepting", 0, nil, 0, 0],
        ["hetzner-fsn1", "x64", "premium", "accepting", 10, 16, 80, 256]
      ].each do |location, arch, family, allocation_state, used_cores, total_cores, used_hugepages_1g, total_hugepages_1g|
        create_vm_host(location_id: Location[name: location].id, arch:, family:, allocation_state:, used_cores:, total_cores:, used_hugepages_1g:, total_hugepages_1g:)
      end

      expect(Clog).to receive(:emit).with("location utilization") do |&blk|
        dat = blk.call[:location_utilization]
        if dat[:location_id] == Location::HETZNER_FSN1_ID && dat[:arch] == "x64" && dat[:family] == "standard" && dat[:allocation_state] == "accepting"
          expect(dat[:core_utilization]).to eq(30.0)
          expect(dat[:hugepage_utilization]).to eq(25.0)
        elsif dat[:location_id] == Location::HETZNER_FSN1_ID && dat[:arch] == "x64" && dat[:family] == "standard" && dat[:allocation_state] == "draining"
          expect(dat[:core_utilization]).to eq(25.0)
          expect(dat[:hugepage_utilization]).to eq(33.33)
        end
      end.exactly(5)

      expect(Clog).to receive(:emit).with("arch utilization") do |&blk|
        dat = blk.call[:arch_utilization]
        if dat[:arch] == "x64" && dat[:family] == "standard"
          expect(dat[:core_utilization]).to eq(25)
          expect(dat[:hugepage_utilization]).to eq(22.22)
        elsif dat[:arch] == "x64" && dat[:family] == "premium"
          expect(dat[:core_utilization]).to eq(62.5)
          expect(dat[:hugepage_utilization]).to eq(31.25)
        elsif dat[:arch] == "arm64" && dat[:family] == "standard"
          expect(dat[:core_utilization]).to eq(12.5)
          expect(dat[:hugepage_utilization]).to eq(15.0)
        end
      end.exactly(3)

      expect { lvmhu.wait }.to nap(60)
    end
  end
end
