# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "cli ai api-key create" do
  it "creates api key" do
    expect(ApiKey.where(owner_table: "project").count).to eq 0
    cli(%w[ai api-key create])
    expect(ApiKey.where(owner_table: "project").count).to eq 1
  end
end
