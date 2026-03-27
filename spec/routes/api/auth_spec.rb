# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  it "invalid authorization header" do
    header "Authorization", "Bearer wrongjwt"
    get "/project"
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")

    header "Authorization", "Bearer pat-"
    get "/project"
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")
  end

  it "no authorization header" do
    get "/project"

    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end

  it "rejects PAT with nonexistent api key" do
    # Valid UBID format but no matching ApiKey record
    header "Authorization", "Bearer pat-#{"a" * 26}-#{"b" * 32}"
    get "/project"
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")
  end

  it "rejects PAT with wrong key" do
    account = create_account
    project = account.create_project_with_default_policy("test")
    pat = ApiKey.create_personal_access_token(account, project:)

    header "Authorization", "Bearer pat-#{pat.ubid}-wrongkey"
    get "/project"
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")
  end
end
