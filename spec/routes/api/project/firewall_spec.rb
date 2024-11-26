# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:firewall) { Firewall.create_with_id(name: "default-firewall", location: "hetzner-fsn1").tap { _1.associate_with_project(project) } }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/firewall"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not create" do
      post "/project/#{project.ubid}/firewall"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success get all firewalls" do
      Firewall.create_with_id(name: "#{firewall.name}-2", location: "hetzner-fsn1").associate_with_project(project)

      get "/project/#{project.ubid}/firewall"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
