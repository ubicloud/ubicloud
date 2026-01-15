# frozen_string_literal: true

module Validation
  class PostgresConfigValidator
    def initialize(version)
      case version
      when "17"
        @config_schema = Validation::PostgresConfigValidatorSchema::PG_17_CONFIG_SCHEMA
      when "16"
        @config_schema = Validation::PostgresConfigValidatorSchema::PG_16_CONFIG_SCHEMA
      when "18"
        @config_schema = Validation::PostgresConfigValidatorSchema::PG_18_CONFIG_SCHEMA
      when "pgbouncer"
        @config_schema = Validation::PostgresConfigValidatorSchema::PGBOUNCER_CONFIG_SCHEMA
      else
        raise "Unsupported version: #{version}"
      end
    end

    def validate(config)
      errors = validation_errors(config)

      if errors.any?
        raise Validation::ValidationFailed.new(errors)
      end
    end

    def validation_errors(config)
      errors = {}
      config.each do |key, value|
        errors[key] = if value.to_s.empty?
          "Value cannot be empty"
        elsif valid_config?(key)
          validate_config(key, value)
        elsif key.split(".").length == 2
          # Unknown customized option, ignore validation for it.
          # Ref: https://www.postgresql.org/docs/17/runtime-config-custom.html#RUNTIME-CONFIG-CUSTOM
          nil
        else
          "Unknown configuration parameter"
        end
      end
      errors.compact!
      errors
    end

    private

    def valid_config?(key)
      @config_schema.key?(key)
    end

    def validate_config(key, value)
      config = @config_schema[key]
      errors = []

      begin
        value = Integer(value) if config[:type] == :integer
      rescue
        errors << "must be an integer"
      end

      begin
        value = Float(value) if config[:type] == :float
      rescue
        errors << "must be a float"
      end

      # Validate type
      case config[:type]
      when :integer
        errors << validate_integer_range(value, config[:min], config[:max]) if value.is_a?(Integer)
      when :float
        errors << validate_float_range(value, config[:min], config[:max]) if value.is_a?(Float)
      when :enum
        errors << validate_enum(value, config[:allowed_values])
      when :string
        errors << validate_string(value, config[:pattern])
      when :bool
        errors << validate_bool(value)
      else
        errors << "Unknown type #{config[:type]}"
      end

      errors.compact!
      errors.any? ? errors : nil
    end

    def validate_integer_range(value, min, max)
      return nil if value.between?(min, max)

      "must be between #{min} and #{max}"
    end

    def validate_float_range(value, min, max)
      return nil if value.between?(min, max)

      "must be between #{min} and #{max}"
    end

    def validate_enum(value, allowed_values)
      return nil if allowed_values.include?(value)

      "must be one of: #{allowed_values.join(", ")}"
    end

    def validate_string(value, pattern)
      # Check pattern validation first if pattern is specified
      if pattern && !pattern.match?(value)
        return "must match pattern: #{pattern.source.gsub(/[\\Az]/, "")}"
      end

      # Check if string value needs quoting and is properly quoted
      quoting_error = validate_string_quoting(value)
      return quoting_error if quoting_error

      nil
    end

    def validate_string_quoting(value)
      # Ref: https://www.postgresql.org/docs/9.3/config-setting.html#CONFIG-SETTING-CONFIGURATION-FILE
      is_quoted = value.start_with?("'") && value.end_with?("'")

      if is_quoted
        inner_value = value[1...-1]

        # Single quotes inside should be escaped as '' or '\
        escaped_quotes_removed = inner_value.gsub("''", "").gsub("\\'", "")

        if escaped_quotes_removed.include?("'")
          "contains unescaped single quotes - single quotes must be doubled ('') inside quoted strings"
        end
      elsif !value.match?(/\A[a-zA-Z0-9_]+\z/)
        "must be wrapped in single quotes (e.g., '#{value.gsub("'", "''")}') because it contains special characters"
      end
    end

    def validate_bool(value)
      return nil if ["on", "of", "off", "t", "tr", "tru", "true", "f", "fa", "fal", "fals", "false", "1", "0"].include?(value.downcase)

      "must be 'on' or 'off' or 'true' or 'false' or '1' or '0' or any unambiguous prefix of these values (case-insensitive)"
    end
  end
end
