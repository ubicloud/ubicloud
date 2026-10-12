# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp firewall tools" do
  let(:fw) { Firewall.create(name: "fw-1", description: "web tier", location_id: Location::HETZNER_FSN1_ID, project_id: @project.id) }
  let(:rule) { FirewallRule.create(firewall_id: fw.id, cidr: "10.0.0.0/8", port_range: Sequel.pg_range(22...23), protocol: "tcp", description: "ssh") }

  let(:row) do
    {
      "id" => fw.ubid,
      "name" => "fw-1",
      "description" => "web tier",
      "location" => "eu-central-h1",
      "firewall_rules" => [{"id" => rule.ubid, "cidr" => "10.0.0.0/8", "port_range" => "22", "protocol" => "tcp", "description" => "ssh"}],
    }
  end

  before do
    rule
  end

  describe "list_firewall" do
    let(:other_fw) { Firewall.create(name: "fw-2", location_id: Location::HETZNER_FSN1_ID, project_id: @project.id) }

    before do
      other_fw
    end

    it "lists firewalls with their rules" do
      expect(mcp_tool_data("list_firewall")).to match({
        "items" => contain_exactly(row, include("id" => other_fw.ubid, "name" => "fw-2", "firewall_rules" => [])),
        "count" => 2,
        "next_cursor" => nil,
      })
    end

    it "lists only the firewalls in the given location" do
      Firewall.create(name: "hel-fw", location_id: Location::HETZNER_HEL1_ID, project_id: @project.id)
      expect(mcp_tool_data("list_firewall")["count"]).to eq 3
      expect(mcp_tool_data("list_firewall", location: "eu-central-h1")["items"].map { it["name"] }).to contain_exactly("fw-1", "fw-2")
    end

    it "works with a token restricted to Firewall:view" do
      restrict_pat_to("Firewall:view")
      expect(mcp_tool_data("list_firewall")["items"].map { it["id"] }).to contain_exactly(fw.ubid, other_fw.ubid)
    end

    it "returns an empty list when the token lacks Firewall:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_data("list_firewall")).to eq({"items" => [], "count" => 0, "next_cursor" => nil})
    end

    it "pages in id order" do
      first, second = [fw, other_fw].sort_by(&:id)

      page = mcp_tool_data("list_firewall", limit: 1)
      expect(page["items"].map { it["id"] }).to eq [first.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to eq first.ubid

      page = mcp_tool_data("list_firewall", limit: 2, cursor: page["next_cursor"])
      expect(page["items"].map { it["id"] }).to eq [second.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to be_nil
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("list_firewall", location: "nowhere")).to start_with "InvalidLocation: "
    end

    it "rejects a location that is not a display name" do
      ["eu-central-h1/vm/test-vm/serial-log?", "eu-central-h1/vm/test-vm/serial-log?\nx"].each do |location|
        expect(mcp_tool_error("list_firewall", location:)).to eq "InvalidRequest: location must be a display name such as eu-central-h1"
      end
    end
  end

  describe "get_firewall" do
    let(:ps) { Prog::Vnet::SubnetNexus.assemble(@project.id, name: "dummy-ps-1", firewall_id: fw.id).subject }

    let(:details) do
      row.merge("private_subnets" => [{
        "id" => ps.ubid,
        "name" => "dummy-ps-1",
        "state" => "available",
        "location" => "eu-central-h1",
        "net4" => ps.net4.to_s,
        "net6" => ps.net6.to_s,
        "firewalls" => [row],
        "nics" => [],
      }])
    end

    before do
      ps
    end

    it "returns the firewall with its private subnets by location/name" do
      expect(mcp_tool_data("get_firewall", ref: "eu-central-h1/fw-1")).to eq details
    end

    it "returns the firewall by id" do
      expect(mcp_tool_data("get_firewall", ref: fw.ubid)).to eq details
    end

    it "works with a token restricted to Firewall:view" do
      restrict_pat_to("Firewall:view")
      expect(mcp_tool_data("get_firewall", ref: "eu-central-h1/fw-1")).to eq details
      expect(mcp_tool_data("get_firewall", ref: fw.ubid)).to eq details
    end

    it "returns Forbidden by name and ResourceNotFound by id when the token lacks Firewall:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_firewall", ref: "eu-central-h1/fw-1")).to eq "Forbidden: Sorry, you don't have permission to continue with this request."
      expect(mcp_tool_error("get_firewall", ref: fw.ubid)).to start_with "ResourceNotFound: "
    end

    it "rejects a malformed ref and an id of another type" do
      expect(mcp_tool_error("get_firewall", ref: "foo")).to eq "InvalidRequest: ref must be location/name or a fw... id"
      expect(mcp_tool_error("get_firewall", ref: ps.ubid)).to eq "InvalidRequest: ref must be location/name or a fw... id"
    end

    it "returns ResourceNotFound for an unknown name or id" do
      expect(mcp_tool_error("get_firewall", ref: "eu-central-h1/nope")).to start_with "ResourceNotFound: "
      expect(mcp_tool_error("get_firewall", ref: "fw345678901234567890123456")).to start_with "ResourceNotFound: "
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("get_firewall", ref: "nowhere/fw-1")).to start_with "InvalidLocation: "
    end
  end
end
