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
        expect(described_class.validate_vm_size("standard-2", "x64").name).to eq("standard-2")
      end

      it "invalid vm size" do
        expect { described_class.validate_vm_size("standard-3", "x64") }.to raise_error described_class::ValidationFailed
      end

      it "no IO limits for standard x64" do
        io_limits = described_class.validate_vm_size("standard-2", "x64").io_limits
        expect(io_limits.max_read_mbytes_per_sec).to be_nil
        expect(io_limits.max_write_mbytes_per_sec).to be_nil
      end

      it "no IO limits for standard arm64" do
        io_limits = described_class.validate_vm_size("standard-2", "arm64").io_limits
        expect(io_limits.max_read_mbytes_per_sec).to be_nil
        expect(io_limits.max_write_mbytes_per_sec).to be_nil
      end

      it "no IO limits for standard-gpu" do
        io_limits = described_class.validate_vm_size("standard-gpu-6", "x64").io_limits
        expect(io_limits.max_read_mbytes_per_sec).to be_nil
        expect(io_limits.max_write_mbytes_per_sec).to be_nil
      end
    end

    describe "#validate_vm_storage_size" do
      it "valid vm storage sizes" do
        [
          ["standard-2", "40"],
          ["standard-2", "80"],
          ["standard-4", "160"]
        ].each do |vm_size, storage_size|
          expect(described_class.validate_vm_storage_size(vm_size, "x64", storage_size)).to eq(storage_size.to_f)
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
          expect { described_class.validate_vm_storage_size(vm_size, "x64", storage_size) }.to raise_error described_class::ValidationFailed
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

      it "succeeds if rate limits are set" do
        expect { described_class.validate_storage_volumes([{encrypted: true, max_read_mbytes_per_sec: 10, max_write_mbytes_per_sec: 10}], 0) }.not_to raise_error
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

    describe "#validate_port" do
      it "valid port" do
        expect(described_class.validate_port(:src_port, "1234")).to eq(1234)
      end

      it "invalid port" do
        expect { described_class.validate_port(:src_port, "abc") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_port(:dst_port, "65555") }.to raise_error described_class::ValidationFailed
        expect { described_class.validate_port(:dst_port, "-1") }.to raise_error described_class::ValidationFailed
      end
    end

    describe "#validate_load_balancer_ports" do
      it "validates list of ports" do
        expect { described_class.validate_load_balancer_ports([[80, 80]]) }.not_to raise_error
      end

      it "validates list of ports which hold duplicates" do
        expect { described_class.validate_load_balancer_ports([[80, 80], [443, 80]]) }.to raise_error described_class::ValidationFailed
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
        expect { described_class.validate_boot_image("almalinux-9") }.not_to raise_error
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

    describe "#validate_cloudflare_turnstile" do
      it "no ops when cloudflare site key not configured" do
        expect(Config).to receive(:cloudflare_turnstile_site_key).and_return(nil)
        expect(described_class.validate_cloudflare_turnstile("cf_response")).to be_nil
      end

      it "valid cloudflare response" do
        expect(Config).to receive(:cloudflare_turnstile_site_key).and_return("cf_site_key")
        Excon.stub({url: "https://challenges.cloudflare.com/turnstile/v0/siteverify", method: :post}, {status: 200, body: {"success" => true}.to_json})
        expect(described_class.validate_cloudflare_turnstile("cf_response")).to be_nil
      end

      it "invalid cloudflare response" do
        expect(Config).to receive(:cloudflare_turnstile_site_key).and_return("cf_site_key")
        Excon.stub({url: "https://challenges.cloudflare.com/turnstile/v0/siteverify", method: :post}, {status: 200, body: {"success" => false, "error-codes" => "123"}.to_json})
        expect { described_class.validate_cloudflare_turnstile("cf_response") }.to raise_error described_class::ValidationFailed
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

  describe "#validate_url" do
    it "valid account names" do
      [
        "https://example.com",
        "https://example.com:1234"
      ].each do |url|
        expect(described_class.validate_url(url)).to be_nil
      end
    end

    it "invalid account names" do
      [
        nil,
        "",
        "1.2.3.4",
        "http://example.com",
        "https://",
        "ftp://example.com"
      ].each do |url|
        expect { described_class.validate_url(url) }.to raise_error described_class::ValidationFailed
      end
    end
  end

  describe "#validate_vcpu_quota" do
    it "sufficient cpu quota" do
      p = instance_double(Project, current_resource_usage: 5, effective_quota_value: 10, quota_available?: true)
      expect { described_class.validate_vcpu_quota(p, "VmVCpu", 2) }.not_to raise_error
    end

    it "insufficient cpu quota" do
      p = instance_double(Project, current_resource_usage: 10, effective_quota_value: 10, quota_available?: false)
      expect { described_class.validate_vcpu_quota(p, "VmVCpu", 2) }.to raise_error described_class::ValidationFailed
    end
  end

  describe "#validate_billing_rate" do
    it "valid billing rate" do
      expect { described_class.validate_billing_rate("VmVCpu", "standard", "hetzner-fsn1") }.not_to raise_error
    end

    it "invalid billing rate" do
      expect { described_class.validate_billing_rate("VmVCpu", "burstable", "latitude-fra") }.to raise_error described_class::ValidationFailed
    end
  end

  describe "#validate_load_balancer_stack" do
    it "valid load balancer stack" do
      expect { described_class.validate_load_balancer_stack("ipv4") }.not_to raise_error
      expect { described_class.validate_load_balancer_stack("ipv6") }.not_to raise_error
      expect { described_class.validate_load_balancer_stack("dual") }.not_to raise_error
    end

    it "invalid load balancer stack" do
      expect { described_class.validate_load_balancer_stack("invalid") }.to raise_error described_class::ValidationFailed
    end
  end

  describe "#validate_kubernetes_name" do
    it "valid names" do
      [
        "abc",
        "abc123",
        "abc-123",
        "123abc",
        "abc--123",
        "a-b-c-1-2",
        "a" * 40
      ].each do |name|
        expect(described_class.validate_kubernetes_name(name)).to be_nil
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
        "a" * 42
      ].each do |name|
        expect { described_class.validate_kubernetes_name(name) }.to raise_error described_class::ValidationFailed
      end
    end
  end

  describe "#validate_kubernetes_cp_node_count" do
    it "valid numbers" do
      [1, 3].each do |count|
        expect(described_class.validate_kubernetes_cp_node_count(count)).to be_nil
      end
    end

    it "invalid numbers" do
      [-37, 0, 2, 4, 5].each do |count|
        expect { described_class.validate_kubernetes_cp_node_count(count) }.to raise_error described_class::ValidationFailed
      end
    end
  end

  describe "#validate_private_location_name" do
    it "validates aws region names" do
      expect { described_class.validate_provider_location_name("aws", "us-west-2") }.not_to raise_error
      expect { described_class.validate_provider_location_name("aws", "eu-central-2") }.to raise_error described_class::ValidationFailed
      expect { described_class.validate_provider_location_name("azure", "us-east-1") }.to raise_error described_class::ValidationFailed
    end
  end

  describe "#validate_victoria_metrics_username" do
    it "valid usernames" do
      [
        "abc",
        "abc123",
        "abc-123",
        "abc_123",
        "abc--123",
        "a-b-c-1-2",
        "a_b_c_1_2",
        "a" * 32
      ].each do |username|
        expect(described_class.validate_victoria_metrics_username(username)).to be_nil
      end
    end

    it "invalid usernames" do
      [
        nil,
        "ab",
        "-abc",
        "ABC",
        "123abc",
        "abc$",
        "a" * 33
      ].each do |username|
        expect { described_class.validate_victoria_metrics_username(username) }.to raise_error described_class::ValidationFailed
      end
    end
  end

  describe "#validate_victoria_metrics_storage_size" do
    it "valid storage sizes" do
      [1, 100, 2000, 4000].each do |size|
        expect(described_class.validate_victoria_metrics_storage_size(size)).to eq(size)
      end
    end

    it "invalid storage sizes" do
      [0, -1, 4001, 5000].each do |size|
        expect { described_class.validate_victoria_metrics_storage_size(size) }.to raise_error described_class::ValidationFailed
      end
    end

    it "converts string input to integer" do
      expect(described_class.validate_victoria_metrics_storage_size("100")).to eq(100)
    end
  end

  describe "#validate_rfc3339_datetime_str" do
    it "validates RFC 3339 datetime strings" do
      ["2025-05-12T11:57:24+00:00", "2025-05-12T11:57:24+05:30", "2025-05-12T11:57:24-02:00"].each do |datetime_str|
        expect { described_class.validate_rfc3339_datetime_str(datetime_str) }.not_to raise_error
      end
    end

    it "invalidates non-RFC 3339 datetime strings" do
      ["1747053663", "abc", "2025-05-12T11:57:24"].each do |datetime_str|
        expect { described_class.validate_rfc3339_datetime_str(datetime_str) }.to raise_error described_class::ValidationFailed
      end
    end

    it "converts string input to Time" do
      expect(described_class.validate_rfc3339_datetime_str("2025-05-12T11:57:24+00:00")).to be_a(Time)
    end
  end

  describe "#validate_postgres_upgrade" do
    it "validates postgres upgrade" do
      expect {
        described_class.validate_postgres_upgrade(
          instance_double(
            PostgresResource,
            can_upgrade?: true,
            needs_convergence?: false,
            ongoing_failover?: false,
            read_replica?: false,
            flavor: PostgresResource::Flavor::STANDARD
          )
        )
      }.not_to raise_error
    end

    it "invalidates postgres upgrade when needs_convergence is true" do
      expect {
        described_class.validate_postgres_upgrade(
          instance_double(
            PostgresResource,
            version: "16",
            target_version: "16",
            needs_convergence?: true,
            ongoing_failover?: false,
            read_replica?: false
          )
        )
      }.to raise_error described_class::ValidationFailed
    end

    it "invalidates postgres upgrade when read_replica is true" do
      expect {
        described_class.validate_postgres_upgrade(
          instance_double(
            PostgresResource,
            version: "16",
            target_version: "16",
            needs_convergence?: false,
            ongoing_failover?: false,
            read_replica?: true
          )
        )
      }.to raise_error described_class::ValidationFailed
    end

    it "invalidates postgres upgrade when flavor is lantern" do
      expect {
        described_class.validate_postgres_upgrade(
          instance_double(
            PostgresResource,
            version: "16",
            target_version: "16",
            needs_convergence?: false,
            ongoing_failover?: false,
            read_replica?: false,
            flavor: PostgresResource::Flavor::LANTERN
          )
        )
      }.to raise_error described_class::ValidationFailed
    end

    it "invalidates postgres upgrade when it cannot be upgraded" do
      expect {
        described_class.validate_postgres_upgrade(
          instance_double(
            PostgresResource,
            can_upgrade?: false,
            needs_convergence?: false,
            ongoing_failover?: false,
            read_replica?: false,
            flavor: PostgresResource::Flavor::STANDARD
          )
        )
      }.to raise_error described_class::ValidationFailed
    end
  end

  describe "#validate_postgres_version" do
    it "validates postgres version" do
      expect {
        described_class.validate_postgres_version("16", PostgresResource::Flavor::STANDARD)
      }.not_to raise_error
    end

    it "invalidates postgres version" do
      expect {
        described_class.validate_postgres_version("18", PostgresResource::Flavor::LANTERN)
      }.to raise_error described_class::ValidationFailed
    end
  end
end
