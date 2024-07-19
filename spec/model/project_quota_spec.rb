# frozen_string_literal: true

require_relative "spec_helper"

require "json"

RSpec.describe ProjectQuota do
  it "has unique resource types" do
    resource_types = described_class.default_quotas.map { |resource_type, _| resource_type }
    expect(resource_types.size).to eq(resource_types.uniq.size)
  end

  it "has unique ids" do
    ids = described_class.default_quotas.map { |_, quota| quota["id"] }
    expect(ids.size).to eq(ids.uniq.size)
  end
end
