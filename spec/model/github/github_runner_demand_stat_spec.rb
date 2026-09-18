# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe GithubRunnerDemandStat do
  describe ".track_arrival" do
    it "creates a row on first arrival without sampling a rate (no prior data point)" do
      expect {
        described_class.track_arrival("ubicloud-standard-2")
      }.to change(described_class, :count).from(0).to(1)

      stat = described_class.first
      expect(stat.label).to eq("ubicloud-standard-2")
      expect(stat.arch).to eq("x64")
      expect(stat.ewma_rate).to eq(0)
      expect(stat.last_arrival_at).not_to be_nil
    end

    it "samples a rate into the EWMA on subsequent arrivals" do
      described_class.track_arrival("ubicloud-standard-2")
      stat = described_class.first
      stat.this.update(last_arrival_at: Time.now - 2)

      described_class.track_arrival("ubicloud-standard-2")

      stat.reload
      expect(stat.ewma_rate).to be > 0
      expect(stat.ewma_rate).to be_within(0.01).of(0.5 * Config.vm_pool_ewma_rate_alpha)
    end

    it "does nothing for an unrecognized label" do
      expect {
        described_class.track_arrival("not-a-real-label")
      }.not_to change(described_class, :count)
    end

    it "keeps separate rows per arch" do
      described_class.track_arrival("ubicloud-standard-2")
      described_class.track_arrival("ubicloud-standard-2-arm")

      expect(described_class.count).to eq(2)
      expect(described_class.select_map(:arch).sort).to eq(%w[arm64 x64])
    end
  end

  describe ".track_completion" do
    it "is a no-op when no stat row exists yet" do
      expect {
        described_class.track_completion("ubicloud-standard-2", 120)
      }.not_to change(described_class, :count)
    end

    it "does nothing for an unrecognized label" do
      described_class.track_arrival("ubicloud-standard-2")
      expect {
        described_class.track_completion("not-a-real-label", 120)
      }.not_to change { described_class.first.ewma_hold_time }
    end

    it "samples hold time into the EWMA" do
      described_class.track_arrival("ubicloud-standard-2")

      described_class.track_completion("ubicloud-standard-2", 100)

      stat = described_class.first
      expect(stat.ewma_hold_time).to be_within(0.01).of(100 * Config.vm_pool_ewma_hold_alpha)
    end
  end

  describe "#target_size" do
    it "floors and ceils the computed target" do
      stat = described_class.create(label: "ubicloud-standard-2", arch: "x64", ewma_rate: 0, ewma_hold_time: 0)
      expect(stat.target_size).to eq(Config.vm_pool_size_floor)

      stat.update(ewma_rate: 1000, ewma_hold_time: 1000)
      expect(stat.target_size).to eq(Config.vm_pool_size_ceiling)
    end
  end
end
