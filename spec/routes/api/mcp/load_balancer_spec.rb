# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp load balancer tools" do
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(@project.id, name: "dummy-ps-1").subject }
  let(:lb) { Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-1", src_port: 80, dst_port: 8080).subject }

  let(:row) do
    {
      "id" => lb.ubid,
      "name" => "lb-1",
      "location" => "eu-central-h1",
      "hostname" => lb.hostname,
      "algorithm" => "round_robin",
      "stack" => "dual",
      "health_check_endpoint" => "/up",
      "health_check_protocol" => "http",
      "src_port" => 80,
      "dst_port" => 8080,
      "cert_enabled" => false,
    }
  end

  before do
    lb
  end

  describe "list_load_balancer" do
    let(:other_lb) { Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-2", src_port: 443, dst_port: 8443).subject }

    before do
      other_lb
    end

    it "lists load balancers with their summary fields" do
      expect(mcp_tool_data("list_load_balancer")).to match({
        "items" => contain_exactly(row, include("id" => other_lb.ubid, "name" => "lb-2", "src_port" => 443, "dst_port" => 8443)),
        "count" => 2,
        "next_cursor" => nil,
      })
    end

    it "lists only the load balancers in the given location" do
      hel_ps = Prog::Vnet::SubnetNexus.assemble(@project.id, name: "hel-ps", location_id: Location::HETZNER_HEL1_ID).subject
      Prog::Vnet::LoadBalancerNexus.assemble(hel_ps.id, name: "hel-lb", src_port: 80, dst_port: 8080)
      expect(mcp_tool_data("list_load_balancer")["count"]).to eq 3
      expect(mcp_tool_data("list_load_balancer", location: "eu-central-h1")["items"].map { it["name"] }).to contain_exactly("lb-1", "lb-2")
    end

    it "works with a token restricted to LoadBalancer:view" do
      restrict_pat_to("LoadBalancer:view")
      expect(mcp_tool_data("list_load_balancer")["items"].map { it["id"] }).to contain_exactly(lb.ubid, other_lb.ubid)
    end

    it "returns an empty list when the token lacks LoadBalancer:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_data("list_load_balancer")).to eq({"items" => [], "count" => 0, "next_cursor" => nil})
    end

    it "pages in id order" do
      first, second = [lb, other_lb].sort_by(&:id)

      page = mcp_tool_data("list_load_balancer", limit: 1)
      expect(page["items"].map { it["id"] }).to eq [first.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to eq first.ubid

      page = mcp_tool_data("list_load_balancer", limit: 2, cursor: page["next_cursor"])
      expect(page["items"].map { it["id"] }).to eq [second.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to be_nil
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("list_load_balancer", location: "nowhere")).to start_with "InvalidLocation: "
    end

    it "rejects a location that is not a display name" do
      ["eu-central-h1/vm/test-vm/serial-log?", "eu-central-h1/vm/test-vm/serial-log?\nx"].each do |location|
        expect(mcp_tool_error("list_load_balancer", location:)).to eq "InvalidRequest: location must be a display name such as eu-central-h1"
      end
    end
  end

  describe "get_load_balancer" do
    let(:vm) { create_vm(project_id: @project.id) }
    let(:details) { row.merge("subnet" => "dummy-ps-1", "vms" => [vm.ubid]) }

    before do
      lb.add_vm(vm)
    end

    it "returns the load balancer with its subnet and VM ids by location/name" do
      expect(mcp_tool_data("get_load_balancer", ref: "eu-central-h1/lb-1")).to eq details
    end

    it "returns the load balancer by id" do
      expect(mcp_tool_data("get_load_balancer", ref: lb.ubid)).to eq details
    end

    it "returns the load balancer by id when another subnet in the location has one of the same name" do
      other_ps = Prog::Vnet::SubnetNexus.assemble(@project.id, name: "dummy-ps-2").subject
      other_lb = Prog::Vnet::LoadBalancerNexus.assemble(other_ps.id, name: "lb-1", src_port: 443, dst_port: 8443).subject
      expect(mcp_tool_data("get_load_balancer", ref: lb.ubid)).to eq details
      expect(mcp_tool_data("get_load_balancer", ref: other_lb.ubid)).to include("id" => other_lb.ubid, "subnet" => "dummy-ps-2", "src_port" => 443)
    end

    it "works with a token restricted to LoadBalancer:view" do
      restrict_pat_to("LoadBalancer:view")
      expect(mcp_tool_data("get_load_balancer", ref: "eu-central-h1/lb-1")).to eq details
      expect(mcp_tool_data("get_load_balancer", ref: lb.ubid)).to eq details
    end

    it "returns Forbidden by name and ResourceNotFound by id when the token lacks LoadBalancer:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_load_balancer", ref: "eu-central-h1/lb-1")).to eq "Forbidden: Sorry, you don't have permission to continue with this request."
      expect(mcp_tool_error("get_load_balancer", ref: lb.ubid)).to start_with "ResourceNotFound: "
    end

    it "rejects a malformed ref and an id of another type" do
      expect(mcp_tool_error("get_load_balancer", ref: "foo")).to eq "InvalidRequest: ref must be location/name or a 1b... id"
      expect(mcp_tool_error("get_load_balancer", ref: vm.ubid)).to eq "InvalidRequest: ref must be location/name or a 1b... id"
    end

    it "returns ResourceNotFound for an unknown name or id" do
      expect(mcp_tool_error("get_load_balancer", ref: "eu-central-h1/nope")).to start_with "ResourceNotFound: "
      expect(mcp_tool_error("get_load_balancer", ref: "1b345678901234567890123456")).to start_with "ResourceNotFound: "
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("get_load_balancer", ref: "nowhere/lb-1")).to start_with "InvalidLocation: "
    end
  end
end
