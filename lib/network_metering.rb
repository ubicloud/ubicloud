# frozen_string_literal: true

require_relative "network_metering/provider/aws"
require_relative "network_metering/provider/gcp"

module NetworkMetering
  PROVIDERS = {"aws" => Provider::Aws, "gcp" => Provider::Gcp}.freeze
end
