# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "private_subnet" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/private-subnet"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success all pss" do
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2", location: "hetzner-fsn1")
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-3", location: "hetzner-fsn1")

      get "/project/#{project.ubid}/private-subnet"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
