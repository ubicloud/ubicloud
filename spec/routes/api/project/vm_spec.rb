# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:vm) { Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-1").subject }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/vm"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success all vms" do
      Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2", location: "hetzner-fsn1")
      Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-3", location: vm.location)

      get "/project/#{project.ubid}/vm"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(3)
    end
  end
end
