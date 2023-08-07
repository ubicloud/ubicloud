# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-1").vm
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  let(:vm_wo_permission) { Prog::Vm::Nexus.assemble("dummy-public-key", project_wo_permissions.id, name: "dummy-vm-2").vm }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project/#{project.ubid}/location/#{vm.location}/vm"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/location/#{vm.location}/vm"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    describe "list" do
      it "empty" do
        get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq([])
      end

      it "success" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).length).to eq(1)
      end
    end

    describe "create" do
      it "success" do
        expect(BillingRecord).to receive(:create)

        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm", {
          public_key: "ssh key",
          name: "test-vm",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
      end

      it "invalid name" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm", {
          public_key: "ssh key",
          name: "invalid name",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["name"]).to eq("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm/#{vm.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "not found" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm/not-exists-vm"

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "delete" do
      it "success" do
        delete "/api/project/#{project.ubid}/location/#{vm.location}/vm/#{vm.name}"

        expect(last_response.status).to eq(200)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end
    end
  end
end
