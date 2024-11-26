# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/load-balancer"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
      lb_project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:load_balancer_service_project_id).and_return(lb_project.id)
    end

    it "success all load balancers" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "subnet-1", location: "hetzner-fsn1")
      Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-1", src_port: 80, dst_port: 80)
      Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-2", src_port: 80, dst_port: 80)
      get "/project/#{project.ubid}/load-balancer"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
