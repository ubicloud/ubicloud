# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  it "invalid authorization header" do
    header "Authorization", "Bearer wrongjwt"
    get "/project"
    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")

    header "Authorization", "Bearer pat-"
    get "/project"
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")
  end

  it "no authorization header" do
    get "/project"

    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end

  describe "with require_mfa_or_omniauth feature flag" do
    let(:account) { create_account }

    let(:project) do
      project = project_with_default_policy(account)
      project.set_ff_require_mfa_or_omniauth(true)
      project
    end

    before do
      login_api
    end

    it "allows access if account for token has otp authentication setup" do
      DB[:account_otp_keys].insert(id: account.id, key: "1")
      get "/project/#{project.ubid}"
      expect(last_response.status).to eq(200)
    end

    it "allows access if account for token has webauthn authentication setup" do
      DB[:account_webauthn_keys].insert(account_id: account.id, webauthn_id: "1", public_key: "1", name: "1", sign_count: 0)
      get "/project/#{project.ubid}"
      expect(last_response.status).to eq(200)
    end

    it "allows access if account does not have password authentication" do
      DB[:account_password_hashes].where(id: account.id).delete
      get "/project/#{project.ubid}"
      expect(last_response.status).to eq(200)
    end

    it "denies access if account allows access via password authentication" do
      get "/project/#{project.ubid}"
      expect(last_response).to have_api_error(403, "Project #{project.ubid} requires token's account to have multifactor authentication enabled or login only allowed via external provider")
    end
  end
end
