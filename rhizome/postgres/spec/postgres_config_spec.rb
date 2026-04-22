# frozen_string_literal: true

require_relative "../lib/postgres_config"

RSpec.describe PostgresConfig do
  describe ".quote_value" do
    it "wraps a simple value in single quotes" do
      expect(described_class.quote_value("value")).to eq("'value'")
    end

    it "wraps a value with spaces" do
      expect(described_class.quote_value("read committed")).to eq("'read committed'")
    end

    it "escapes single quotes by doubling" do
      expect(described_class.quote_value("my'app")).to eq("'my''app'")
    end

    it "escapes backslashes by doubling" do
      expect(described_class.quote_value("test\\n")).to eq("'test\\\\n'")
    end

    it "escapes both single quotes and backslashes" do
      expect(described_class.quote_value("it's a \\test")).to eq("'it''s a \\\\test'")
    end

    it "converts integers to string" do
      expect(described_class.quote_value(100)).to eq("'100'")
    end

    it "handles empty string" do
      expect(described_class.quote_value("")).to eq("''")
    end

    it "preserves double quotes" do
      expect(described_class.quote_value('"/tmp/my dir", /tmp')).to eq(%('"/tmp/my dir", /tmp'))
    end
  end

  describe ".format" do
    it "formats a config hash for postgresql.conf" do
      config = {"max_connections" => 100, "default_transaction_isolation" => "read committed"}
      result = described_class.format(config)
      expect(result).to eq("max_connections = '100'\ndefault_transaction_isolation = 'read committed'")
    end

    it "returns empty string for empty hash" do
      expect(described_class.format({})).to eq("")
    end

    it "escapes values that need quoting" do
      config = {"app" => "my'app", "cmd" => "test \\n"}
      result = described_class.format(config)
      expect(result).to eq("app = 'my''app'\ncmd = 'test \\\\n'")
    end
  end
end
