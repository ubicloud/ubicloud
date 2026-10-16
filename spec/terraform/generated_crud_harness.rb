# frozen_string_literal: true

require_relative "spec_helper"
require_relative "resource_registry"
require_relative "shared/generated_crud"

RSpec.describe "terraform: generated CRUD baselines" do
  # Iterate definitions, not registry keys: a conforming new
  # resource is covered with ZERO registry lines.
  TerraformGenerator.resources.filter_map { |n, d| n if d.emitted_kinds.include?(:resource) }.each do |resource_name|
    describe "ubicloud_#{resource_name}" do
      include_examples "generated resource CRUD", resource_name
    end
  end
end
