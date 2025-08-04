# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe BootImage do
  subject(:boot_image) { described_class.new }

  describe "#remove_boot_image" do
    it "creates a strand to delete boot image" do
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("RemoveBootImage")
        expect(args[:label]).to eq("start")
        expect(args[:stack]).to eq([{subject_id: 1}])
      end
      boot_image.id = 1
      boot_image.remove_boot_image
    end
  end
end
