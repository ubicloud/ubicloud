# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "private_subnet" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/private-subnet"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "success all pss" do
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location_id: Location::HETZNER_FSN1_ID)
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-3", location_id: Location::HETZNER_FSN1_ID)

      get "/project/#{project.ubid}/private-subnet"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
