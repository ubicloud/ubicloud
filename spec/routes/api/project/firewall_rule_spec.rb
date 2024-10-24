# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:firewall) { Firewall.create_with_id(name: "default-firewall", location: "hetzner-hel1").tap { _1.associate_with_project(project) } }

  let(:firewall_rule) { FirewallRule.create_with_id(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80..5432)) }

  describe "unauthenticated" do
    it "not post" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "create firewall rule" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule", {
        cidr: "0.0.0.0/0",
        port_range: "100..101"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "can not create same firewall rule" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule", {
        cidr: firewall_rule.cidr,
        port_range: "80..5432"
      }.to_json

      expect(last_response).to have_api_error(400, "cidr and port_range and firewall_id is already taken")
    end

    it "firewall rule no port range" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule", {
        cidr: "0.0.0.0/1"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "firewall rule single port" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule", {
        cidr: "0.0.0.0/1",
        port_range: "11111"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "firewall rule delete" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"
      expect(last_response.status).to eq(204)
    end

    it "firewall rule delete does not exist" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule/fooubid"
      expect(last_response.status).to eq(204)
    end

    it "success get firewall rule" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule/#{firewall_rule.ubid}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/firewall-rule/fooubid"

      expect(last_response.content_type).to eq("application/json")
      expect(last_response).to have_api_error(404)
    end
  end
end
