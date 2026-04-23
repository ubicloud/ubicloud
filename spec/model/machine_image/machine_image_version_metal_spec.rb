# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MachineImageVersionMetal do
  let(:metal) {
    described_class.new(
      archive_kek_id: StorageKeyEncryptionKey.create_random(auth_data: "k").id,
      store_id: nil, store_prefix: "p", enabled: false, archive_size_mib: nil,
    )
  }

  describe "#display_state" do
    it "is creating while archive hasn't populated archive_size_mib yet" do
      expect(metal.display_state).to eq("creating")
    end

    it "is ready once enabled" do
      metal.set(enabled: true, archive_size_mib: 100)
      expect(metal.display_state).to eq("ready")
    end

    it "is destroying after enabled is flipped back to false" do
      metal.set(enabled: false, archive_size_mib: 100)
      expect(metal.display_state).to eq("destroying")
    end
  end
end
