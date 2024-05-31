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

    describe "#validate_vm_size" do
      it "valid vm size" do
        expect(described_class.validate_vm_size("standard-2").name).to eq("standard-2")
      end

      it "invalid vm size" do
        expect { described_class.validate_vm_size("standard-3") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_vm_storage_size" do
      it "valid vm storage sizes" do
        [
          ["standard-2", "40"],
          ["standard-2", "60"],
          ["standard-4", "160"]
        ].each do |vm_size, storage_size|
          expect(described_class.validate_vm_storage_size(vm_size, storage_size)).to eq(storage_size.to_f)
        end
      end

      it "invalid vm storage sizes" do
        [
          ["standard-2", "160"],
          ["standard-2", "37.4"],
          ["standard-2", ""],
          ["standard-2", nil],
          ["standard-5", "40"],
          [nil, "40"]
        ].each do |vm_size, storage_size|
          expect { described_class.validate_vm_storage_size(vm_size, storage_size) }.to raise_error described_class::ValidationFailed
        end
      end
    end

    describe "#validate_location" do
      it "valid locations" do
        [
          "hetzner-hel1",
          "hetzner-fsn1",
          "github-runners"
        ].each do |location|
          expect(described_class.validate_location(location)).to be_nil
        end
      end

      it "invalid locations" do
        [
          "hetzner-hel2",
          "hetzner-fsn2"
        ].each do |location|
          expect { described_class.validate_location(location) }.to raise_error described_class::ValidationFailed
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

    describe "#validate_postgres_storage_size" do
      it "valid postgres storage sizes" do
        [
          ["standard-2", "128"],
          ["standard-2", "256"],
          ["standard-4", "1024"]
        ].each do |pg_size, storage_size|
          expect(described_class.validate_postgres_storage_size(pg_size, storage_size)).to eq(storage_size.to_f)
        end
      end

      it "invalid postgres storage sizes" do
        [
          ["standard-2", "1024"],
          ["standard-2", "37.4"],
          ["standard-2", ""],
          ["standard-2", nil],
          ["standard-5", "128"],
          [nil, "128"]
        ].each do |pg_size, storage_size|
          expect { described_class.validate_postgres_storage_size(pg_size, storage_size) }.to raise_error described_class::ValidationFailed
        end
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

    describe "#validate_port_range" do
      it "valid port range" do
        expect(described_class.validate_port_range("1234")).to eq([1234])
        expect(described_class.validate_port_range("1234..1235")).to eq([1234, 1235])
        expect(described_class.validate_port_range("1234..1234")).to eq([1234, 1234])
      end

      it "invalid port range" do
        expect { described_class.validate_port_range("") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_port_range("65555") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_port_range("0..65555") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_port_range("10..9") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_port_range("65556..65556") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_cidr" do
      it "valid cidr" do
        expect { described_class.validate_cidr("0.0.0.0/0") }.not_to raise_error
        expect { described_class.validate_cidr("0.0.0.0/1") }.not_to raise_error
        expect { described_class.validate_cidr("192.168.1.0/24") }.not_to raise_error
        expect { described_class.validate_cidr("255.255.255.255/0") }.not_to raise_error

        expect { described_class.validate_cidr("::/0") }.not_to raise_error
        expect { described_class.validate_cidr("::1/128") }.not_to raise_error
        expect { described_class.validate_cidr("2001:db8::/32") }.not_to raise_error
      end

      it "invalid cidr" do
        expect { described_class.validate_cidr("192.168.1.256/24") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_cidr("10.256.0.0/8") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_cidr("172.16.0.0/33") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_cidr("not_a_cidr") }.to raise_error described_class::ValidationFailed

        expect { described_class.validate_cidr("::1/129") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_cidr("::1/::1") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_boot_image" do
      it "valid boot image" do
        expect { described_class.validate_boot_image("ubuntu-jammy") }.not_to raise_error
      end

      it "invalid boot image" do
        expect { described_class.validate_boot_image("invalid-boot-image") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_boot_image("postgres-ubuntu-2204") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_short_text" do
      it "valid short text" do
        expect { described_class.validate_short_text("abcABC123()!?* ", "name") }.not_to raise_error
      end

      it "invalid short text" do
        expect { described_class.validate_short_text("", "name") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_short_text("a" * 256, "name") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_short_text("'", "name") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_short_text("%", "name") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_short_text("~", "name") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_usage_limit" do
      it "valid usage limit" do
        expect(described_class.validate_usage_limit("123")).to eq(123)
      end

      it "invalid usage limit" do
        expect { described_class.validate_usage_limit("abc") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_usage_limit("0") }.to raise_error described_class::ValidationFailed
      end
    end
  end

  describe "#validate_account_name" do
    it "valid account names" do
      [
        "John Doe",
        "john doe",
        "John Doe-Smith",
        "Jøhn Döe",
        "John2 Doe",
        "J" * 63
      ].each do |name|
        expect(described_class.validate_account_name(name)).to be_nil
      end
    end

    it "invalid account names" do
      [
        nil,
        "",
        " John Doe",
        "1john Doe",
        ".john Doe",
        "https://example.com",
        "Click this link: http://example.com",
        "Click this link example.com",
        "🚀 emojis not allowed",
        "J" * 64
      ].each do |name|
        expect { described_class.validate_account_name(name) }.to raise_error described_class::ValidationFailed
      end
    end
  end
end
