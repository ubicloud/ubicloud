# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  let(:user) { create_account }

  it "wrong email" do
    post "/login?login=wrong_mail&password=#{TEST_USER_PASSWORD}", nil, {"CONTENT_TYPE" => "application/json"}

    expect(last_response).to have_api_error(401, "There was an error logging in")
  end

  it "wrong password" do
    post "/login?login=#{TEST_USER_EMAIL}&password=wrongpassword", nil, {"CONTENT_TYPE" => "application/json"}

    expect(last_response).to have_api_error(401, "There was an error logging in")
  end

  it "JSON body with array parameters" do
    post "/login?login=wrong_mail&password=#{TEST_USER_PASSWORD}", [].to_json, {"CONTENT_TYPE" => "application/json"}

    expect(last_response).to have_api_error(401, "There was an error logging in")
  end

  it "JSON body with invalid JSON" do
    post "/login?login=wrong_mail&password=#{TEST_USER_PASSWORD}", "'", {"CONTENT_TYPE" => "application/json"}

    expect(last_response).to have_api_error(400, "invalid JSON uploaded")
  end

  it "wrong jwt" do
    header "Authorization", "Bearer wrongjwt"
    get "/project"

    expect(last_response).to have_api_error(400, "invalid JWT format or claim in Authorization header")
  end

  it "no login" do
    get "/project"

    expect(last_response).to have_api_error(401, "Please login to continue")
  end
end
