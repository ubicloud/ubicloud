# frozen_string_literal: true

require "uri"

module Validation
  class CsiConfigValidator
    SCHEMA = {
      "EXTERNAL_ENDPOINTS" => {
        type: :endpoints,
        default: "ipv4.google.com:443",
        workload: :nodeplugin,
      },
      "DISK_LIMIT_GB" => {
        type: :integer,
        min: 10,
        max: 300,
        default: "10",
        workload: :provisioner,
      },
      "RESERVE_PERCENT" => {
        type: :integer,
        min: 10,
        max: 50,
        default: "20",
        workload: :provisioner,
      },
    }.freeze

    DEFAULTS = SCHEMA.transform_values { it[:default] }.freeze

    def self.workload(key)
      SCHEMA.fetch(key)[:workload]
    end

    def self.validate(config, errors)
      config.each do |key, value|
        message = error_for(key, value)
        errors.add(:csi_config, "#{key} #{message}") if message
      end
    end

    def self.error_for(key, value)
      schema = SCHEMA[key]
      return "is not a known CSI configuration key" unless schema
      return "must be a string" unless value.is_a?(String)

      if schema[:type] == :integer
        integer_error(value, schema)
      else
        endpoints_error(value)
      end
    end

    def self.integer_error(value, schema)
      number = Integer(value, 10, exception: false)
      return "must be an integer" unless number

      "must be between #{schema[:min]} and #{schema[:max]}" unless number.between?(schema[:min], schema[:max])
    end

    def self.endpoints_error(value)
      "must be a comma separated list of host:port" unless parse_endpoints(value)
    end

    def self.canonicalize(key, value)
      return value unless SCHEMA.dig(key, :type) == :endpoints

      parse_endpoints(value) || value
    end

    def self.parse_endpoints(value)
      value.split(",").map do |endpoint|
        host, colon, port = endpoint.strip.rpartition(":")
        return nil if colon.empty?

        number = Integer(port, 10, exception: false)
        return nil unless number&.between?(1, 65535) && valid_host?(host)

        "#{host}:#{number}"
      end.join(",")
    end

    def self.valid_host?(host)
      uri = URI("https://")
      uri.host = host.include?(":") ? "[#{host}]" : host
      true
    rescue URI::InvalidComponentError
      false
    end
  end
end
