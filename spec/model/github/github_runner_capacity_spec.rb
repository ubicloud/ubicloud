# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRunnerCapacity do
  let(:pool) { described_class["x64-standard"].update(total_cores: 100, total_hugepages_1g: 400, used_cores: 90, used_hugepages_1g: 100) }
  let(:spill) { described_class[described_class::SPILL].update(used_vcpus: 96, used_runners: 10) }
  let(:amounts) { {used_cores: 4, used_hugepages_1g: 16} }

  describe ".charge" do
    it "charges a pool within its utilization" do
      expect(described_class.charge(pool.name, amounts, described_class.metal_room(amounts, 95))).to be(true)
      expect(pool.reload.values.values_at(:used_cores, :used_hugepages_1g)).to eq([94, 116])
    end

    it "does not charge a pool past its utilization" do
      expect(described_class.charge(pool.name, amounts, described_class.metal_room(amounts, 93))).to be(false)
      expect(pool.reload.used_cores).to eq(90)
    end

    it "checks the hugepages too" do
      pool.update(used_hugepages_1g: 375)
      expect(described_class.charge(pool.name, amounts, described_class.metal_room(amounts, 97))).to be(false)
    end

    it "charges a pool without a condition" do
      expect(described_class.charge(pool.name, {used_cores: 20, used_hugepages_1g: 0})).to be(true)
      expect(pool.reload.used_cores).to eq(110)
    end

    it "charges the spill capacity within its configured limits" do
      expect(Config).to receive(:github_runner_aws_spill_vcpu_capacity).and_return(100).twice
      expect(Config).to receive(:github_runner_aws_spill_runner_capacity).and_return(50).twice
      expect(described_class.charge(spill.name, {used_vcpus: 4, used_runners: 1}, described_class.spill_room({used_vcpus: 4, used_runners: 1}))).to be(true)
      expect(described_class.charge(spill.name, {used_vcpus: 4, used_runners: 1}, described_class.spill_room({used_vcpus: 4, used_runners: 1}))).to be(false)
      expect(spill.reload.values.values_at(:used_vcpus, :used_runners)).to eq([100, 11])
    end
  end

  describe ".refund" do
    it "stops the usage at zero" do
      described_class.refund(pool.name, {used_cores: 95, used_hugepages_1g: 4})
      expect(pool.reload.values.values_at(:used_cores, :used_hugepages_1g)).to eq([0, 96])
    end
  end
end
