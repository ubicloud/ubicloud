# frozen_string_literal: true

RSpec.describe GithubStoragePolicy do
  subject(:sp) {
    described_class.new({
      "github_installation_name" => "A",
      "use_bdev_ubi_rate" => 0.2,
      "skip_sync_rate" => 0.8,
      "encrypted_rate" => 0.5
    })
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
  end
end
