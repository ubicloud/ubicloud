# frozen_string_literal: true

module TerraformGenerator
  SPEC = File.expand_path("../../openapi/openapi.yml", __dir__)
  SpecError = Class.new(StandardError)
end

require_relative "terraform_generator/api"
