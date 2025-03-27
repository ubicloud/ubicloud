# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  it "invalid authorization header" do
    header "Authorization", "Bearer wrongjwt"
    get "/project"

    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end

  it "no authorization header" do
    get "/project"

    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end
end
