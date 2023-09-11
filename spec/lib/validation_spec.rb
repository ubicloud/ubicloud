# frozen_string_literal: true

RSpec.describe Validation do
  describe "#validate_name" do
    it "valid names" do
      [
        "abc",
        "abc123",
        "abc-123",
        "123abc",
        "abc--123",
        "a-b-c-1-2",
        "a" * 63
      ].each do |name|
        expect(described_class.validate_name(name)).to be_nil
      end
    end

    it "invalid names" do
      [
        "-abc",
        "abc-",
        "-abc-",
        "ABC",
        "ABC_123",
        "ABC$123",
        "a" * 64
      ].each do |name|
        expect { described_class.validate_name(name) }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_provider" do
      it "valid provider" do
        expect(described_class.validate_provider("hetzner")).to be_nil
      end

      it "invalid provider" do
        expect { described_class.validate_provider("hetzner-cloud") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_vm_size" do
      it "valid vm size" do
        expect(described_class.validate_vm_size("standard-2").name).to eq("standard-2")
      end

      it "invalid vm size" do
        expect { described_class.validate_vm_size("standard-3") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_location" do
      it "valid locations" do
        [
          ["hetzner-hel1", nil],
          ["hetzner-hel1", "hetzner"],
          ["github-runners", "hetzner"]
        ].each do |location, provider|
          expect(described_class.validate_location(location, provider)).to be_nil
        end
      end

      it "invalid locations" do
        [
          ["hetzner-hel2", nil],
          ["hetzner-hel2", "hetzner"]
        ].each do |location, provider|
          expect { described_class.validate_location(location, provider) }.to raise_error described_class::ValidationFailed
        end
      end
    end

    describe "#validate_os_user_name" do
      it "valid os user names" do
        [
          "abc",
          "abc123",
          "abc-123",
          "abc_123",
          "_abc",
          "abc-_-123",
          "a-b-c-1-2",
          "a" * 32
        ].each do |name|
          expect(described_class.validate_os_user_name(name)).to be_nil
        end
      end

      it "invalid os user names" do
        [
          "-abc",
          "ABC",
          "123abc",
          "abc$",
          "a" * 33
        ].each do |name|
          expect { described_class.validate_os_user_name(name) }.to raise_error described_class::ValidationFailed
        end
      end
    end

    describe "#validate_storage_volumes" do
      it "succeeds if there's at least one volume" do
        expect(described_class.validate_storage_volumes([{encrypted: true}], 0)).to be_nil
      end

      it "fails if no volumes" do
        expect { described_class.validate_storage_volumes([], 0) }.to raise_error described_class::ValidationFailed
      end

      it "fails if boot_disk_index out of range" do
        expect { described_class.validate_storage_volumes([{encrypted: true}], -1) }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_storage_volumes([{encrypted: true}], 1) }.to raise_error described_class::ValidationFailed
      end
    end
  end
end
