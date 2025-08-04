# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/load-balancer"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
      lb_project = Project.create(name: "default")
      allow(Config).to receive(:load_balancer_service_project_id).and_return(lb_project.id)
    end

    it "success all load balancers" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "subnet-1", location_id: Location::HETZNER_FSN1_ID)
      Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-1", src_port: 80, dst_port: 80)
      Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-2", src_port: 80, dst_port: 80)
      get "/project/#{project.ubid}/load-balancer"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
