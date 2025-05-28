# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:firewall) { Firewall.create_with_id(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }

  describe "unauthenticated" do
    it "not delete" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not get" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not associate" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}/attach-subnet"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "not dissociate" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}/detach-subnet"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "success get all location firewalls" do
      Firewall.create_with_id(name: "#{firewall.name}-2", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)

      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    it "success get firewall" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist for valid name" do
      get "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/fooname"

      expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
    end

    it "success post" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/foo-name", {
        description: "Firewall description"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "success delete with underscore" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}"

      expect(last_response.status).to eq(204)
      expect(firewall).not_to exist
    end

    it "raises unauthorized access error if one of firewall's private subnets is not authorized" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      AccessControlEntry.dataset.destroy
      AccessControlEntry.create(project_id: project.id, subject_id: user.id, object_id: firewall.id)
      AccessControlEntry.create(project_id: project.id, subject_id: @pat.id, object_id: firewall.id)

      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}"

      expect(last_response.status).to eq(403)
      expect(firewall).to exist
    end

    it "delete for non-existant ubid" do
      delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{Firewall.generate_ubid}"

      expect(last_response.status).to eq(204)
      expect(firewall).to exist
    end

    it "attach to subnet" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.private_subnets.count).to eq(1)
      expect(firewall.private_subnets.first.id).to eq(ps.id)
      expect(last_response.status).to eq(200)
      expect(ps.update_firewall_rules_set?).to be true
    end

    it "attach to subnet not exist" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: "fooubid"
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id")
    end

    it "detach from subnet" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/detach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(last_response.status).to eq(200)
      expect(ps.update_firewall_rules_set?).to be true
    end

    it "detach from subnet not exist" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/detach-subnet", {
        private_subnet_id: "fooubid"
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id")
    end

    it "attach and detach" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: Location::HETZNER_FSN1_ID).subject

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.private_subnets.count).to eq(1)
      expect(ps.update_firewall_rules_set?).to be true
      Semaphore.where(strand_id: ps.id, name: "update_firewall_rules").destroy

      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.ubid}/detach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.reload.private_subnets.count).to eq(0)
      expect(ps.update_firewall_rules_set?).to be true
    end

    it "location not exist" do
      post "/project/#{project.ubid}/location/not-exist-location/firewall/test-firewall", {
        description: "Firewall description"
      }.to_json

      expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
    end
  end
end
