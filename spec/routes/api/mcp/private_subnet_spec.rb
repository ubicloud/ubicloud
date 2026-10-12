# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp private subnet tools" do
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(@project.id, name: "dummy-ps-1").subject }
  let(:fw) { ps.firewalls.first }
  let(:nic) { Prog::Vnet::NicNexus.assemble(ps.id, name: "test-vm-nic").subject.update(vm_id: create_vm(project_id: @project.id).id) }

  let(:row) do
    rules = fw.firewall_rules.sort
    {
      "id" => ps.ubid,
      "name" => "dummy-ps-1",
      "state" => "available",
      "location" => "eu-central-h1",
      "net4" => ps.net4.to_s,
      "net6" => ps.net6.to_s,
      "firewalls" => [{
        "id" => fw.ubid,
        "name" => "dummy-ps-1-default",
        "description" => "Default firewall",
        "location" => "eu-central-h1",
        "firewall_rules" => [
          {"id" => rules[0].ubid, "cidr" => "0.0.0.0/0", "port_range" => "0..65535", "protocol" => "tcp", "description" => ""},
          {"id" => rules[1].ubid, "cidr" => "0.0.0.0/0", "port_range" => "0..65535", "protocol" => "udp", "description" => ""},
          {"id" => rules[2].ubid, "cidr" => "::/0", "port_range" => "0..65535", "protocol" => "tcp", "description" => ""},
          {"id" => rules[3].ubid, "cidr" => "::/0", "port_range" => "0..65535", "protocol" => "udp", "description" => ""},
        ],
      }],
      "nics" => [{
        "id" => nic.ubid,
        "name" => "test-vm-nic",
        "private_ipv4" => nic.private_ipv4_address,
        "private_ipv6" => nic.private_ipv6_address,
        "vm_name" => "test-vm",
      }],
    }
  end

  before do
    nic
  end

  describe "list_private_subnet" do
    let(:other_ps) { Prog::Vnet::SubnetNexus.assemble(@project.id, name: "dummy-ps-2").subject }

    before do
      other_ps
    end

    it "lists private subnets with their firewalls and NICs" do
      expect(mcp_tool_data("list_private_subnet")).to match({
        "items" => contain_exactly(row, include("id" => other_ps.ubid, "name" => "dummy-ps-2", "nics" => [])),
        "count" => 2,
        "next_cursor" => nil,
      })
    end

    it "lists only the private subnets in the given location" do
      Prog::Vnet::SubnetNexus.assemble(@project.id, name: "hel-ps", location_id: Location::HETZNER_HEL1_ID)
      expect(mcp_tool_data("list_private_subnet")["count"]).to eq 3
      expect(mcp_tool_data("list_private_subnet", location: "eu-central-h1")["items"].map { it["name"] }).to contain_exactly("dummy-ps-1", "dummy-ps-2")
    end

    it "works with a token restricted to PrivateSubnet:view" do
      restrict_pat_to("PrivateSubnet:view")
      expect(mcp_tool_data("list_private_subnet")["items"].map { it["id"] }).to contain_exactly(ps.ubid, other_ps.ubid)
    end

    it "returns an empty list when the token lacks PrivateSubnet:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_data("list_private_subnet")).to eq({"items" => [], "count" => 0, "next_cursor" => nil})
    end

    it "pages in id order" do
      first, second = [ps, other_ps].sort_by(&:id)

      page = mcp_tool_data("list_private_subnet", limit: 1)
      expect(page["items"].map { it["id"] }).to eq [first.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to eq first.ubid

      page = mcp_tool_data("list_private_subnet", limit: 2, cursor: page["next_cursor"])
      expect(page["items"].map { it["id"] }).to eq [second.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to be_nil
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("list_private_subnet", location: "nowhere")).to start_with "InvalidLocation: "
    end

    it "rejects a location that is not a display name" do
      ["eu-central-h1/vm/test-vm/serial-log?", "eu-central-h1/vm/test-vm/serial-log?\nx"].each do |location|
        expect(mcp_tool_error("list_private_subnet", location:)).to eq "InvalidRequest: location must be a display name such as eu-central-h1"
      end
    end
  end

  describe "get_private_subnet" do
    it "returns the private subnet by location/name" do
      expect(mcp_tool_data("get_private_subnet", ref: "eu-central-h1/dummy-ps-1")).to eq row
    end

    it "returns the private subnet by id" do
      expect(mcp_tool_data("get_private_subnet", ref: ps.ubid)).to eq row
    end

    it "works with a token restricted to PrivateSubnet:view" do
      restrict_pat_to("PrivateSubnet:view")
      expect(mcp_tool_data("get_private_subnet", ref: "eu-central-h1/dummy-ps-1")).to eq row
      expect(mcp_tool_data("get_private_subnet", ref: ps.ubid)).to eq row
    end

    it "returns Forbidden by name and ResourceNotFound by id when the token lacks PrivateSubnet:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_private_subnet", ref: "eu-central-h1/dummy-ps-1")).to eq "Forbidden: Sorry, you don't have permission to continue with this request."
      expect(mcp_tool_error("get_private_subnet", ref: ps.ubid)).to start_with "ResourceNotFound: "
    end

    it "rejects a malformed ref and an id of another type" do
      expect(mcp_tool_error("get_private_subnet", ref: "foo")).to eq "InvalidRequest: ref must be location/name or a ps... id"
      expect(mcp_tool_error("get_private_subnet", ref: fw.ubid)).to eq "InvalidRequest: ref must be location/name or a ps... id"
    end

    it "returns ResourceNotFound for an unknown name or id" do
      expect(mcp_tool_error("get_private_subnet", ref: "eu-central-h1/nope")).to start_with "ResourceNotFound: "
      expect(mcp_tool_error("get_private_subnet", ref: "ps345678901234567890123456")).to start_with "ResourceNotFound: "
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("get_private_subnet", ref: "nowhere/dummy-ps-1")).to start_with "InvalidLocation: "
    end
  end
end
