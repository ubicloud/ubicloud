# frozen_string_literal: true

RSpec.describe Validation::PostgresConfigValidatorSchema do
  describe "#schema" do
    it "check if all numbers have min/max values" do
      expect(Validation::PostgresConfigValidatorSchema::PG_16_CONFIG_SCHEMA.select { |k, v| v[:type] == :integer and (v[:max].nil? or v[:min].nil?) }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PG_16_CONFIG_SCHEMA.select { |k, v| v[:type] == :float and (v[:max].nil? or v[:min].nil?) }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PG_17_CONFIG_SCHEMA.select { |k, v| v[:type] == :integer and (v[:max].nil? or v[:min].nil?) }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PG_17_CONFIG_SCHEMA.select { |k, v| v[:type] == :float and (v[:max].nil? or v[:min].nil?) }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PGBOUNCER_CONFIG_SCHEMA.select { |k, v| v[:type] == :integer and (v[:max].nil? or v[:min].nil?) }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PGBOUNCER_CONFIG_SCHEMA.select { |k, v| v[:type] == :float and (v[:max].nil? or v[:min].nil?) }.keys).to be_empty
    end

    it "check if all enums have allowed values" do
      expect(Validation::PostgresConfigValidatorSchema::PG_16_CONFIG_SCHEMA.select { |k, v| v[:type] == :enum and v[:allowed_values].nil? }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PG_17_CONFIG_SCHEMA.select { |k, v| v[:type] == :enum and v[:allowed_values].nil? }.keys).to be_empty
      expect(Validation::PostgresConfigValidatorSchema::PGBOUNCER_CONFIG_SCHEMA.select { |k, v| v[:type] == :enum and v[:allowed_values].nil? }.keys).to be_empty
    end
  end
end
