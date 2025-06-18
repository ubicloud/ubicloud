# frozen_string_literal: true

RSpec.describe Validation::PostgresConfigValidator do
  let(:validator) { described_class.new("17") }

  describe "#initialize" do
    context "with invalid version" do
      it "raises an error" do
        expect { described_class.new("invalid") }.to raise_error(RuntimeError)
      end
    end

    context "with valid version" do
      it "returns a validator instance" do
        expect { described_class.new("16") }.not_to raise_error
        expect { described_class.new("pgbouncer") }.not_to raise_error
      end
    end
  end

  describe "#validate" do
    context "with valid configurations" do
      it "returns no errors for valid max_connections" do
        config = {"max_connections" => 100}
        expect { validator.validate(config) }.not_to raise_error
      end

      it "returns no errors for valid log_statement" do
        config = {"log_statement" => "ddl"}
        expect { validator.validate(config) }.not_to raise_error
      end

      it "returns no errors for valid shared_buffers" do
        config = {"shared_buffers" => "128MB"}
        expect { validator.validate(config) }.not_to raise_error
      end

      it "returns no errors for valid autovacuum_analyze_scale_factor" do
        config = {"autovacuum_analyze_scale_factor" => 0.1}
        expect { validator.validate(config) }.not_to raise_error
      end

      it "returns no errors for setting a string with no validation" do
        config = {"archive_command" => "foo bar"}
        expect { validator.validate(config) }.not_to raise_error
      end

      it "returns no errors for setting a bool with no validation" do
        config = {"allow_system_table_mods" => "on"}
        expect { validator.validate(config) }.not_to raise_error
      end

      it "returns no errors for unknown customized option" do
        config = {"citus.shard_count" => "32"}
        expect { validator.validate(config) }.not_to raise_error
      end
    end

    context "with invalid configurations" do
      it "returns error for invalid max_connections" do
        config = {"max_connections" => "abc"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for out of range max_connections" do
        config = {"max_connections" => 10001}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for invalid log_statement value" do
        config = {"log_statement" => "invalid"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for invalid shared_buffers format" do
        config = {"shared_buffers" => "invalid"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for invalid float value" do
        config = {"autovacuum_analyze_scale_factor" => "invalid"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for out of range float value" do
        config = {"autovacuum_analyze_scale_factor" => -1.0}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for invalid bool value" do
        config = {"allow_system_table_mods" => "invalid"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end
    end

    context "with unknown configurations" do
      it "returns error for unknown config" do
        config = {"unknown_config" => "value"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end

      it "returns error for invalid customized option" do
        config = {"invalid.customized.option" => "32"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end
    end

    context "with invalid type configuration" do
      it "returns error for invalid type value" do
        sample_config_schema = {"max_connections" => {type: :none}}
        validator.instance_variable_set(:@config_schema, sample_config_schema)
        config = {"max_connections" => "100"}
        expect { validator.validate(config) }.to raise_error(Validation::ValidationFailed)
      end
    end
  end
end
