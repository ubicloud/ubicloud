# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:firewall) { Firewall.create_with_id(name: "default-firewall", location: "hetzner-hel1").tap { _1.associate_with_project(project) } }

  describe "unauthenticated" do
    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not associate" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}/attach-subnet"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not dissociate" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}/detach-subnet"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success get all location firewalls" do
      Firewall.create_with_id(name: "#{firewall.name}-2", location: "hetzner-hel1").associate_with_project(project)

      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    it "success get firewall" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist for invalid name" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/foo_name"

      expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
    end

    it "get does not exist for valid name" do
      get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/fooname"

      expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
    end

    it "success post" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/foo-name", {
        description: "Firewall description"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "failure post" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/FooName", {
        description: "Firewall description"
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: name")
    end

    it "success delete" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}"

      expect(last_response.status).to eq(204)
    end

    it "delete not exist for valid ubid format" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{"0" * 26}"

      expect(last_response.status).to eq(204)
    end

    it "delete not exist for invalid ubid format" do
      delete "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_foo_ubid"

      expect(last_response.status).to eq(204)
    end

    it "attach to subnet" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(PrivateSubnet).to receive(:from_ubid).and_return(ps)
      expect(ps).to receive(:incr_update_firewall_rules)

      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.private_subnets.count).to eq(1)
      expect(firewall.private_subnets.first.id).to eq(ps.id)
      expect(last_response.status).to eq(200)
    end

    it "attach to subnet not exist" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/attach-subnet", {
        private_subnet_id: "fooubid"
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id")
    end

    it "detach from subnet" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(PrivateSubnet).to receive(:from_ubid).and_return(ps)
      expect(ps).to receive(:incr_update_firewall_rules)

      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/detach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "detach from subnet not exist" do
      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/detach-subnet", {
        private_subnet_id: "fooubid"
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id")
    end

    it "attach and detach" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(PrivateSubnet).to receive(:from_ubid).and_return(ps).twice
      expect(ps).to receive(:incr_update_firewall_rules).twice

      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.private_subnets.count).to eq(1)

      post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/_#{firewall.ubid}/detach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.reload.private_subnets.count).to eq(0)
    end
  end
end
