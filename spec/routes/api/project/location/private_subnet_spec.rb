# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "private_subnet" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1").subject }

  let(:ps_wo_permission) { Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-2").subject }

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"],
        [:post, "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/foo_name"],
        [:delete, "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"],
        [:delete, "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"],
        [:get, "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.ubid}"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    describe "list" do
      it "empty" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(1)
      end

      it "success multiple" do
        Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-2")

        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end

      it "with vm nic" do
        nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32")

        Prog::Vm::Nexus.assemble("dummy-public key", project.id, private_subnet_id: ps.id, nic_id: nic.id, name: "dummy-vm-2")

        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
      end

      it "with nic without vm" do
        Prog::Vnet::NicNexus.assemble(ps.id, name: "dummy-nic",
          ipv6_addr: "fd38:5c12:20bf:67d4:919e::/79",
          ipv4_addr: "172.17.226.186/32")

        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet"

        expect(last_response.status).to eq(200)
      end
    end

    describe "create" do
      it "success" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-ps")
      end

      it "not authorized" do
        project
        post "/project/#{project_wo_permissions.ubid}/location/#{ps_wo_permission.display_location}/private-subnet/foo-subnet"

        expect(last_response.content_type).to eq("application/json")
        expect(last_response).to have_api_error(403)
      end

      it "with valid firewall" do
        fw = Firewall.create_with_id(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps", {firewall_id: fw.ubid}.to_json

        expect(last_response.status).to eq(200)
        resp_body = JSON.parse(last_response.body)
        expect(resp_body["name"]).to eq("test-ps")
        expect(resp_body["firewalls"].first["id"]).to eq(fw.ubid)
      end

      it "with invalid firewall id" do
        firewall_id = "a" * 25 + "b"
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps", {firewall_id:}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: firewall_id", {"firewall_id" => "Firewall with id \"#{firewall_id}\" and location \"eu-central-h1\" is not found"})
      end

      it "with empty body" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/private-subnet/test-ps", {}.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-ps")
      end

      it "location not exist" do
        post "/project/#{project.ubid}/location/not-exist-location/private-subnet/test-ps", {}.to_json

        expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(ps.name)
      end

      it "success id" do
        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(ps.name)
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/not-exists-ps"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "not authorized" do
        project
        get "/project/#{project_wo_permissions.ubid}/location/#{ps_wo_permission.display_location}/private-subnet/#{ps_wo_permission.name}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be true
      end

      it "success id" do
        delete "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be true
      end

      it "not exist ubid" do
        delete "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/foo-name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be false
      end

      it "dependent vm failure" do
        Prog::Vm::Nexus.assemble("dummy-public key", project.id, private_subnet_id: ps.id, name: "dummy-vm-2")

        delete "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response).to have_api_error(409, "Private subnet 'dummy-ps-1' has VMs attached, first, delete them.")
      end

      it "if all dependent vms are marked for deletion the subnet can be deleted" do
        st = Prog::Vm::Nexus.assemble("dummy-public key", project.id, private_subnet_id: ps.id, name: "dummy-vm")
        st.subject.incr_destroy

        delete "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be true
      end

      it "if all dependent vms are being deleted the subnet can be deleted" do
        st = Prog::Vm::Nexus.assemble("dummy-public key", project.id, private_subnet_id: ps.id, name: "dummy-vm")
        st.update(label: "destroy")

        delete "/project/#{project.ubid}/location/#{ps.display_location}/private-subnet/#{ps.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(ps.id).set?("destroy")).to be true
      end

      it "not authorized" do
        project
        delete "/project/#{project_wo_permissions.ubid}/location/#{ps_wo_permission.display_location}/private-subnet/#{ps_wo_permission.name}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end
  end
end
