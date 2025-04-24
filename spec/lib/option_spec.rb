# frozen_string_literal: true

require "rspec"
require_relative "../../lib/option"

RSpec.describe Option do
  describe "#VmSize options" do
    it "no burstable cpu allowed for Standard VMs" do
      expect(Option::VmSizes.map { it.name.include?("burstable-") == (it.cpu_burst_percent_limit > 0) }.all?(true)).to be true
    end

    it "no gpu allowed for non-GPU VMs" do
      expect(Option::VmSizes.map { it.name.include?("gpu") == it.gpu }.all?(true)).to be true
    end

    it "no odd number of vcpus allowed, except for 1" do
      expect(Option::VmSizes.all? { it.vcpus == 1 || it.vcpus.even? }).to be true
    end
  end

  describe "#VmFamily options" do
    it "families include burstables" do
      expect(described_class.families.map(&:name)).to include("burstable")
    end
  end
end
