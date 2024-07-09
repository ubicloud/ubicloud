# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "private_subnet" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1").subject }

  let(:ps_wo_permission) { Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-2").subject }

  describe "unauthenticated" do
    it "not location list" do
      get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/foo_name"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not delete ubid" do
      delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/id/#{ps.ubid}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not get ubid" do
      get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/id/#{ps.ubid}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    describe "list" do
      it "empty" do
        get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(1)
      end

      it "success multiple" do
        Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2")

        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end

      it "with vm nic" do
        nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32")

        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, private_subnet_id: ps.id, nic_id: nic.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
      end

      it "with nic without vm" do
        Prog::Vnet::NicNexus.assemble(ps.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32")

        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
      end
    end

    describe "create" do
      it "success" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-ps")
      end

      it "invalid name" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/invalid_name"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: name", {"name" => "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."})
      end

      it "not authorized" do
        post "/api/project/#{project_wo_permissions.ubid}/location/#{ps_wo_permission.location}/private-subnet/foo_subnet"

        expect(last_response).to have_api_error(403)
      end

      it "with valid firewall" do
        fw = Firewall.create_with_id(name: "default-firewall", location: "hetzner-hel1").tap { _1.associate_with_project(project) }
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps", {firewall_id: fw.ubid}.to_json

        expect(last_response.status).to eq(200)
        resp_body = JSON.parse(last_response.body)
        expect(resp_body["name"]).to eq("test-ps")
        expect(resp_body["firewalls"].first["id"]).to eq(fw.ubid)
      end

      it "with invalid firewall id" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps", {firewall_id: "invalidid"}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: firewall_id", {"firewall_id" => "Firewall with id \"invalidid\" and location \"hetzner-hel1\" is not found"})
      end

      it "with empty body" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps", {}.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-ps")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(ps.name)
      end

      it "success id" do
        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/id/#{ps.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(ps.name)
      end

      it "not found" do
        get "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/not-exists-ps"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "not authorized" do
        get "/api/project/#{project_wo_permissions.ubid}/location/#{ps_wo_permission.display_location}/private-subnet/#{ps_wo_permission.name}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end

    describe "delete" do
      it "success" do
        delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be true
      end

      it "success id" do
        delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/id/#{ps.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be true
      end

      it "not exist ubid in location" do
        delete "/api/project/#{project.ubid}/location/foo_location/private-subnet/id/#{ps.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be false
      end

      it "not exist ubid" do
        delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/id/foo_ubid"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be false
      end

      it "dependent vm failure" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, private_subnet_id: ps.id, name: "dummy-vm-2")

        delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response).to have_api_error(409, "Private subnet 'dummy-ps-1' has VMs attached, first, delete them.")
      end

      it "not exist" do
        delete "/api/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be false
      end

      it "not authorized" do
        delete "/api/project/#{project_wo_permissions.ubid}/location/#{ps_wo_permission.display_location}/private-subnet/#{ps_wo_permission.name}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end
  end
end
