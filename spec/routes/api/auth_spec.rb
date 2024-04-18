# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  let(:user) { create_account }

  it "wrong email" do
    post "/api/login?login=wrong_mail&password=#{TEST_USER_PASSWORD}", nil, {"CONTENT_TYPE" => "application/json"}
    expect(last_response.status).to eq(401)
    expect(JSON.parse(last_response.body)["error"]["message"]).to eq("There was an error logging in")
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidCredentials")
  end

  it "wrong password" do
    post "/api/login?login=#{TEST_USER_EMAIL}&password=wrongpassword", nil, {"CONTENT_TYPE" => "application/json"}
    expect(last_response.status).to eq(401)
    expect(JSON.parse(last_response.body)["error"]["message"]).to eq("There was an error logging in")
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidCredentials")
  end

  it "wrong jwt" do
    header "Authorization", "Bearer wrongjwt"
    get "/api/project"

    expect(last_response.status).to eq(400)
    expect(JSON.parse(last_response.body)["error"]["message"]).to eq("invalid JWT format or claim in Authorization header")
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidRequest")
  end

  it "no login" do
    get "/api/project"

    expect(last_response.status).to eq(401)
    expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("LoginRequired")
  end
end
