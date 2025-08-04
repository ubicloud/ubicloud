# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:firewall) { Firewall.create(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/firewall"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not create" do
      post "/project/#{project.ubid}/firewall"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "success get all firewalls" do
      Firewall.create(name: "#{firewall.name}-2", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)

      get "/project/#{project.ubid}/firewall"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
