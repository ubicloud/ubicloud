# frozen_string_literal: true

require_relative "spec_helper"

# The declared update_verb order is a behavioral contract
# (rename last, config after patch); template refactors must not
# reorder the emitted dispatch. The verb table is the artifact: each
# step carries its name, and the table's order is the dispatch order.
RSpec.describe "terraform: update-verb dispatch order (generated)" do
  TerraformGenerator.resources.each do |name, definition|
    next if definition.update_verbs.empty?

    it "matches the declared order for #{name}" do
      src = File.read(File.join(TerraformGenerator::Emit.provider_repo,
        "internal", "provider", "#{name}_resource.go"))
      emitted = src.scan(/\{name: "(\w+)",$/).flatten
      expect(emitted).to eq definition.update_verbs.map { it[:name].to_s }
    end
  end
end
