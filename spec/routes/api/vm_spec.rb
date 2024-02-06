# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-1").subject
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  let(:vm_wo_permission) { Prog::Vm::Nexus.assemble("dummy-public-key", project_wo_permissions.id, name: "dummy-vm-2").vm }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project/#{project.ubid}/vm"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not location list" do
      get "/api/project/#{project.ubid}/location/#{vm.location}/vm"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/location/#{vm.location}/vm/foo_name"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{vm.location}/vm/#{vm.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not delete ubid" do
      delete "/api/project/#{project.ubid}/location/#{vm.location}/vm/ubid/#{vm.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{vm.location}/vm/#{vm.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not get ubid" do
      get "/api/project/#{project.ubid}/location/#{vm.location}/vm/ubid/#{vm.ubid}"

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
        expect(JSON.parse(last_response.body)["values"]).to eq([])
        expect(JSON.parse(last_response.body)["next_cursor"]).to be_nil
        expect(JSON.parse(last_response.body)["count"]).to eq(0)
      end

      it "success single" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(1)
        expect(JSON.parse(last_response.body)["next_cursor"]).to be_nil
        expect(JSON.parse(last_response.body)["count"]).to eq(1)
      end

      it "success multiple" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.location}/vm"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(2)
        expect(JSON.parse(last_response.body)["next_cursor"]).to be_nil
        expect(JSON.parse(last_response.body)["count"]).to eq(2)
      end

      it "success order column" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          order_column: "name"
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"][0]["id"]).to eq(vm.ubid)
      end

      it "success page size 1" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          page_size: 1
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(1)
        expect(JSON.parse(last_response.body)["count"]).to eq(2)
      end

      it "success page size 2" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          page_size: 2
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(2)
      end

      it "success page size less than count" do
        vm_2 = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, location: vm.location, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          page_size: 1,
          order_column: "name"
        }

        expect(JSON.parse(last_response.body)["next_cursor"]).to eq(vm_2.ubid)
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(1)
      end

      it "success negative page size" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          page_size: -1
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(1)
      end

      it "success non numeric page size" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          page_size: "foo"
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(1)
      end

      it "success cursor" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          cursor: vm.ubid
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"][0]["id"]).to eq(vm.ubid)
      end

      it "success all vms" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2", location: "hetzner-fsn1")
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2", location: vm.location)

        get "/api/project/#{project.ubid}/vm"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["values"].length).to eq(3)
      end

      it "fail cursor" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          cursor: "invalidubid"
        }

        expect(last_response.status).to eq(400)
      end

      it "fail order column" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm", {
          order_column: "invalid-column"
        }

        expect(last_response.status).to eq(400)
      end
    end

    describe "create" do
      it "success" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be false
      end

      it "success with ipv4" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be true
      end

      it "invalid name" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/invalid_name", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["name"]).to eq("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
      end

      it "invalid payment method" do
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
        expect(Project).to receive(:from_ubid).and_return(project)

        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["billing_info"]).to eq("Project doesn't have valid billing information")
      end

      it "invalid body" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", "invalid_body"

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Body isn't a valid JSON object.")
      end

      it "missing required key" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          unix_user: "ubi"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["parameters"]).to eq("Request body must include required parameters: public_key")
      end

      it "non allowed key" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          foo_key: "foo_val"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["parameters"]).to eq("Only following parameters are allowed: public_key, size, unix_user, boot_image, enable_ip4")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm/#{vm.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "success ubid" do
        get "/api/project/#{project.ubid}/location/#{vm.location}/vm/ubid/#{vm.ubid}"

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

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/api/project/#{project.ubid}/location/#{vm.location}/vm/ubid/#{vm.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/api/project/#{project.ubid}/location/#{vm.location}/vm/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end
    end
  end
end
