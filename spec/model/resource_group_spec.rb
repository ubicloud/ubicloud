# frozen_string_literal: true

require "bitarray"
require_relative "../spec_helper"

RSpec.describe ResourceGroup do
  subject(:resource_group) do
    described_class.new(
      name: "standard",
      type: "dedicated",
      allowed_cpus: "2-3",
      cores: 1,
      total_cpu_percent: 200,
      used_cpu_percent: 0,
      total_memory_1g: 4,
      used_memory_1g: 0
      ) { _1.id = "b231a172-8f56-8b10-bbed-8916ea4e5c28" }
  end 

  describe "#inhost_name" do
    it "returns the correct inhost_name" do
      expect(resource_group.inhost_name).to eq("standard.slice")
    end
  end

  describe "#to_cpu_bitmask" do
    it "returns the correct bitmask" do
      expect(resource_group.to_cpu_bitmask.to_s).to eq("0011")
    end
  end

  describe "#from_cpu_bitmask" do
    it "converts a cpu bitmask to a correct allowed cpu set" do
      cpu_array = BitArray.new(8)
      cpu_array[4] = 1
      cpu_array[5] = 1
      resource_group.from_cpu_bitmask(cpu_array)
      expect(resource_group.allowed_cpus).to eq("4-5")
    end
  end
end
