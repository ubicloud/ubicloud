# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:firewall) { Firewall.create_with_id(name: "default-firewall").tap { _1.associate_with_project(project) } }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project/#{project.ubid}/firewall"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/firewall"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/firewall/#{firewall.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/firewall/#{firewall.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not associate" do
      get "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/attach-subnet"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not dissociate" do
      get "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/detach-subnet"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success get all firewalls" do
      Firewall.create_with_id(name: firewall.name).associate_with_project(project)

      get "/api/project/#{project.ubid}/firewall"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    it "success get firewall" do
      get "/api/project/#{project.ubid}/firewall/#{firewall.ubid}"

      expect(last_response.status).to eq(200)
    end

    it "get does not exist" do
      get "/api/project/#{project.ubid}/firewall/foo_ubid"

      expect(last_response.status).to eq(404)
    end

    it "success post" do
      post "/api/project/#{project.ubid}/firewall", {
        name: "foo-name",
        description: "Firewall description"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "success delete" do
      delete "/api/project/#{project.ubid}/firewall/#{firewall.ubid}"

      expect(last_response.status).to eq(204)
    end

    it "delete not exist" do
      delete "/api/project/#{project.ubid}/firewall/foo_ubid"

      expect(last_response.status).to eq(204)
    end

    it "attach to subnet" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(PrivateSubnet).to receive(:from_ubid).and_return(ps)
      expect(ps).to receive(:incr_update_firewall_rules)

      post "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.private_subnets.count).to eq(1)
      expect(firewall.private_subnets.first.id).to eq(ps.id)
      expect(last_response.status).to eq(200)
    end

    it "attach to subnet not exist" do
      post "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: "fooubid"
      }.to_json

      expect(last_response.status).to eq(400)
    end

    it "detach from subnet" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(PrivateSubnet).to receive(:from_ubid).and_return(ps)
      expect(ps).to receive(:incr_update_firewall_rules)

      post "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/detach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(last_response.status).to eq(200)
    end

    it "detach from subnet not exist" do
      post "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/detach-subnet", {
        private_subnet_id: "fooubid"
      }.to_json

      expect(last_response.status).to eq(400)
    end

    it "attach and detach" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(PrivateSubnet).to receive(:from_ubid).and_return(ps).twice
      expect(ps).to receive(:incr_update_firewall_rules).twice

      post "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/attach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.private_subnets.count).to eq(1)

      post "/api/project/#{project.ubid}/firewall/#{firewall.ubid}/detach-subnet", {
        private_subnet_id: ps.ubid
      }.to_json

      expect(firewall.reload.private_subnets.count).to eq(0)
    end
  end
end
