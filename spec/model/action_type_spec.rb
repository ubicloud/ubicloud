# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ActionType do
  it "::NAME_MAP maps action type names to uuids" do
    expect(ActionType::NAME_MAP["Project:view"]).to eq "ffffffff-ff00-835a-87ff-f05a40d85dc0"
  end
end
