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
        nil,
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
          nil,
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
        expect { described_class.validate_storage_volumes([{encrypted: true}], 0) }.not_to raise_error
      end

      it "fails if no volumes" do
        expect { described_class.validate_storage_volumes([], 0) }.to raise_error described_class::ValidationFailed
      end

      it "fails if boot_disk_index out of range" do
        expect { described_class.validate_storage_volumes([{encrypted: true}], -1) }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_storage_volumes([{encrypted: true}], 1) }.to raise_error described_class::ValidationFailed
      end

      it "fails if contains an invalid key" do
        expect { described_class.validate_storage_volumes([xyz: 1], 0) }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_minio_username" do
      it "valid minio user names" do
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
          expect(described_class.validate_minio_username(name)).to be_nil
        end
      end

      it "invalid minio user names" do
        [
          nil,
          "ab",
          "-abc",
          "ABC",
          "123abc",
          "abc$",
          "a" * 33
        ].each do |name|
          expect { described_class.validate_minio_username(name) }.to raise_error described_class::ValidationFailed
        end
      end
    end

    describe "#validate_postgres_size" do
      it "valid postgres size" do
        expect(described_class.validate_postgres_size("standard-2").name).to eq("standard-2")
      end

      it "invalid postgres size" do
        expect { described_class.validate_postgres_size("standard-3") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_postgres_ha_type" do
      it "valid postgres ha_type" do
        [PostgresResource::HaType::NONE, PostgresResource::HaType::ASYNC, PostgresResource::HaType::SYNC].each { |ha_type| expect { described_class.validate_postgres_ha_type(ha_type) }.not_to raise_error }
      end

      it "invalid postgres ha_type" do
        ["quorum", "on", "off"].each { |ha_type| expect { described_class.validate_postgres_ha_type(ha_type) }.to raise_error described_class::ValidationFailed }
      end
    end

    describe "#validate_date" do
      it "valid date" do
        expect(described_class.validate_date("2023-11-30 11:41")).to eq(Time.new(2023, 11, 30, 11, 41, 0, "UTC"))
        expect(described_class.validate_date(Time.new(2023, 11, 30, 11, 41))).to eq(Time.new(2023, 11, 30, 11, 41))
      end

      it "invalid date" do
        expect { described_class.validate_date("") }.to raise_error described_class::ValidationFailed, "Validation failed for following fields: date"
        expect { described_class.validate_date(nil) }.to raise_error described_class::ValidationFailed, "Validation failed for following fields: date"
        expect { described_class.validate_date("invalid-date", "restore_date") }.to raise_error described_class::ValidationFailed, "Validation failed for following fields: restore_date"
      end
    end

    describe "#validate_postgres_superuser_password" do
      it "valid password" do
        expect { described_class.validate_postgres_superuser_password("Dummy-pass-123", "Dummy-pass-123") }.not_to raise_error
      end

      it "invalid password" do
        expect { described_class.validate_postgres_superuser_password("", "") }.to raise_error(described_class::ValidationFailed)
        expect { described_class.validate_postgres_superuser_password("Short1", "Short1") }.to raise_error(described_class::ValidationFailed)
        expect { described_class.validate_postgres_superuser_password("NOLOWERCASE123", "NOLOWERCASE123") }.to raise_error(described_class::ValidationFailed)
        expect { described_class.validate_postgres_superuser_password("nouppercase123", "nouppercase123") }.to raise_error(described_class::ValidationFailed)
        expect { described_class.validate_postgres_superuser_password("nodigitNODIGIT", "nodigitNODIGIT") }.to raise_error(described_class::ValidationFailed)
        expect { described_class.validate_postgres_superuser_password("Different12345", "dIFFERENT12345") }.to raise_error(described_class::ValidationFailed)
      end
    end
  end
end
