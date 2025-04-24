# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "cli ai api-key destroy" do
  it "destroys api key" do
    cli(%w[ai api-key create])
    iak = ApiKey.first(owner_table: "project")
    cli(%W[ai api-key #{iak.ubid} destroy -f])
    expect(iak.exists?).to be false
  end
end
