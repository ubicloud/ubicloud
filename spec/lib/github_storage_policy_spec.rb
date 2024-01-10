# frozen_string_literal: true

RSpec.describe GithubStoragePolicy do
  subject(:sp) {
    described_class.new("x64", rules)
  }

  let(:rules) {
    {
      "x64" => {
        "use_bdev_ubi_rate" => 0.2,
        "skip_sync_rate" => 0.8
      },
      "arm64" => {
        "use_bdev_ubi_rate" => 0.3,
        "skip_sync_rate" => 0.6
      }
    }
  }

  describe "#use_bdev_ubi?" do
    it "returns true with the expected rate" do
      expect(sp).to receive(:rand).and_return(0.15)
      expect(sp.use_bdev_ubi?).to be(true)
    end

    it "returns false with the expected rate" do
      expect(sp).to receive(:rand).and_return(0.55)
      expect(sp.use_bdev_ubi?).to be(false)
    end

    it "returns false for a not listed arch" do
      expect(described_class.new("powerpc", rules).use_bdev_ubi?).to be(false)
    end

    it "works for arm64" do
      sp = described_class.new("arm64", rules)
      expect(sp).to receive(:rand).and_return(0.25, 0.35)
      expect(sp.use_bdev_ubi?).to be(true)
      expect(sp.use_bdev_ubi?).to be(false)
    end
  end

  describe "#skip_sync?" do
    it "returns true with the expected rate" do
      expect(sp).to receive(:rand).and_return(0.75)
      expect(sp.skip_sync?).to be(true)
    end

    it "returns false with the expected rate" do
      expect(sp).to receive(:rand).and_return(0.9)
      expect(sp.skip_sync?).to be(false)
    end

    it "returns false for a not listed arch" do
      expect(described_class.new("powerpc", rules).skip_sync?).to be(false)
    end

    it "works for arm64" do
      sp = described_class.new("arm64", rules)
      expect(sp).to receive(:rand).and_return(0.65, 0.55)
      expect(sp.skip_sync?).to be(false)
      expect(sp.skip_sync?).to be(true)
    end
  end
end
