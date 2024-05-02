# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "private_subnet" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project/#{project.ubid}/private-subnet"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success all pss" do
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location: "hetzner-fsn1")
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-3", location: "hetzner-hel1")

      get "/api/project/#{project.ubid}/private-subnet"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
