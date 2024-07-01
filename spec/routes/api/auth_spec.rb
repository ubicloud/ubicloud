# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  let(:user) { create_account }

  it "wrong email" do
    post "/api/login?login=wrong_mail&password=#{TEST_USER_PASSWORD}", nil, {"CONTENT_TYPE" => "application/json"}

    expect(last_response).to have_api_error(401, "There was an error logging in")
  end

  it "wrong password" do
    post "/api/login?login=#{TEST_USER_EMAIL}&password=wrongpassword", nil, {"CONTENT_TYPE" => "application/json"}

    expect(last_response).to have_api_error(401, "There was an error logging in")
  end

  it "wrong jwt" do
    header "Authorization", "Bearer wrongjwt"
    get "/api/project"

    expect(last_response).to have_api_error(400, "invalid JWT format or claim in Authorization header")
  end

  it "no login" do
    get "/api/project"

    expect(last_response).to have_api_error(401, "Please login to continue")
  end
end
