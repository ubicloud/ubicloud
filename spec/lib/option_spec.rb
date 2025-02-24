# frozen_string_literal: true

require "rspec"
require_relative "../../lib/option"

RSpec.describe Option do
  describe "#VmSize options" do
    it "no burstable cpu allowed for Standard VMs" do
      expect(Option::VmSizes.map { _1.name.include?("standard-") == (_1.cpu_burst_percent_limit == 0) }.all?(true)).to be true
    end

    it "no gpu allowed for non-GPU VMs" do
      expect(Option::VmSizes.map { _1.name.include?("gpu") == _1.gpu }.all?(true)).to be true
    end

    it "no odd number of vcpus allowed, except for 1" do
      expect(Option::VmSizes.all? { _1.vcpus == 1 || _1.vcpus.even? }).to be true
    end
  end

  describe "#VmFamily options" do
    it "families include burstables when use slices" do
      expect(described_class.families(use_slices: true).map(&:name)).to include("burstable")
    end

    it "families exclude burstables when not using slices" do
      expect(described_class.families(use_slices: false).map(&:name)).not_to include("burstable")
    end
  end
end
