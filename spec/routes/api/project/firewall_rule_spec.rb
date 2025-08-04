# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:firewall) { Firewall.create(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }

  let(:firewall_rule) { FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80..5432)) }

  describe "unauthenticated" do
    it "not post" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not delete" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not get" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "create firewall rule" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule", {
        cidr: "0.0.0.0/0",
        port_range: "100..101"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "can not create same firewall rule" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule", {
        cidr: firewall_rule.cidr,
        port_range: "80..5432"
      }.to_json

      expect(last_response).to have_api_error(400, "cidr and port_range and firewall_id is already taken")
    end

    it "firewall rule no port range" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule", {
        cidr: "0.0.0.0/1"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "firewall rule single port" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule", {
        cidr: "0.0.0.0/1",
        port_range: "11111"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "firewall rule delete" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"
      expect(last_response.status).to eq(204)
    end

    it "firewall rule delete does not exist" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule/fr000000000000000000000000"
      expect(last_response.status).to eq(204)
    end

    it "success get firewall rule" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/firewall-rule/fr000000000000000000000000"

      expect(last_response.content_type).to eq("application/json")
      expect(last_response).to have_api_error(404)
    end
  end
end
