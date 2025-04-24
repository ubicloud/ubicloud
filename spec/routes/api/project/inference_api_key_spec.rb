# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "inference api key" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:api_key) { ApiKey.create_inference_api_key(project) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/inference-api-key"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not create" do
      post "/project/#{project.ubid}/inference-api-key"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "success get all inference api keys" do
      get "/project/#{project.ubid}/inference-api-key"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("items" => [])

      api_key
      get "/project/#{project.ubid}/inference-api-key"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("items" => [{"id" => api_key.ubid, "key" => api_key.key}])
    end

    it "success create inference api key" do
      post "/project/#{project.ubid}/inference-api-key"
      api_key = ApiKey.first(owner_table: "project")
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("id" => api_key.ubid, "key" => api_key.key)
    end

    it "success delete inference api key" do
      delete "/project/#{project.ubid}/inference-api-key/#{api_key.ubid}"
      expect(last_response.status).to eq(204)
      expect(api_key.exists?).to be false
    end
  end
end
