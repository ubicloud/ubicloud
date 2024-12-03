# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ActionType do
  it "::NAME_MAP maps action type names to uuids" do
    expect(ActionType::NAME_MAP["Project:view"]).to eq "00000000-0003-835a-8000-000000000003"
  end
end
