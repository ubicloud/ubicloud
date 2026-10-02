# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp vm tools" do
  let(:vm) { create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64") }

  let(:summary) do
    {
      "id" => vm.ubid,
      "name" => "test-vm",
      "state" => "running",
      "location" => "eu-central-h1",
      "size" => "standard-2",
      "unix_user" => "ubi",
      "storage_size_gib" => 0,
      "boot_image" => "ubuntu-jammy",
      "ip6" => "128:1234::2",
      "ip4_enabled" => false,
      "ip4" => "128.0.0.1",
      "maintenance_window_start_at" => nil,
    }
  end

  before do
    add_ipv4_to_vm(vm, "128.0.0.1")
  end

  describe "list_vm" do
    let(:other_vm) { Prog::Vm::Nexus.assemble("dummy-public key", @project.id, name: "dummy-vm-1").subject }

    before do
      other_vm
    end

    it "lists VMs with their summary fields" do
      expect(mcp_tool_data("list_vm")).to match({
        "items" => contain_exactly(summary, include("id" => other_vm.ubid, "name" => "dummy-vm-1", "state" => "creating")),
        "count" => 2,
        "next_cursor" => nil,
      })
    end

    it "lists only the VMs in the given location" do
      create_vm(project_id: @project.id, name: "hel-vm", location_id: Location::HETZNER_HEL1_ID)
      expect(mcp_tool_data("list_vm")["count"]).to eq 3
      expect(mcp_tool_data("list_vm", location: "eu-central-h1")["items"].map { it["name"] }).to contain_exactly("test-vm", "dummy-vm-1")
    end

    it "works with a token restricted to Vm:view" do
      restrict_pat_to("Vm:view")
      expect(mcp_tool_data("list_vm")["items"].map { it["id"] }).to contain_exactly(vm.ubid, other_vm.ubid)
    end

    it "returns an empty list when the token lacks Vm:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_data("list_vm")).to eq({"items" => [], "count" => 0, "next_cursor" => nil})
    end

    it "pages in id order" do
      first, second = [vm, other_vm].sort_by(&:id)

      page = mcp_tool_data("list_vm", limit: 1)
      expect(page["items"].map { it["id"] }).to eq [first.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to eq first.ubid

      page = mcp_tool_data("list_vm", limit: 2, cursor: page["next_cursor"])
      expect(page["items"].map { it["id"] }).to eq [second.ubid]
      expect(page["count"]).to eq 2
      expect(page["next_cursor"]).to be_nil
    end

    it "accepts an integral float limit" do
      first = [vm, other_vm].min_by(&:id)
      page = mcp_tool_data("list_vm", limit: 1.0)
      expect(page["items"].map { it["id"] }).to eq [first.ubid]
      expect(page["next_cursor"]).to eq first.ubid
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("list_vm", location: "nowhere")).to start_with "InvalidLocation: "
    end

    it "rejects a location that is not a display name" do
      vm.update(vm_host_id: create_vm_host.id)
      ["eu-central-h1/vm/test-vm/serial-log?", "eu-central-h1/vm/test-vm/serial-log?\nx"].each do |location|
        expect(mcp_tool_error("list_vm", location:)).to eq "InvalidRequest: location must be a display name such as eu-central-h1"
      end
      expect(Strand.where(prog: "Vm::RunCommandNexus").count).to eq 0
    end
  end

  describe "get_vm" do
    let(:subnet) { @project.default_private_subnet(vm.location) }
    let(:nic) { Prog::Vnet::NicNexus.assemble(subnet.id, name: "test-vm-nic").subject.update(vm_id: vm.id) }
    let(:fw) { subnet.firewalls.first }

    let(:details) do
      rules = fw.firewall_rules.sort
      summary.merge(
        "firewalls" => [{
          "id" => fw.ubid,
          "name" => "default-eu-central-h1-default",
          "description" => "Default firewall",
          "location" => "eu-central-h1",
          "firewall_rules" => [
            {"id" => rules[0].ubid, "cidr" => "0.0.0.0/0", "port_range" => "0..65535", "protocol" => "tcp", "description" => ""},
            {"id" => rules[1].ubid, "cidr" => "0.0.0.0/0", "port_range" => "0..65535", "protocol" => "udp", "description" => ""},
            {"id" => rules[2].ubid, "cidr" => "::/0", "port_range" => "0..65535", "protocol" => "tcp", "description" => ""},
            {"id" => rules[3].ubid, "cidr" => "::/0", "port_range" => "0..65535", "protocol" => "udp", "description" => ""},
          ],
          "path" => "/location/eu-central-h1/firewall/default-eu-central-h1-default",
        }],
        "private_ipv4" => nic.private_ipv4_address,
        "private_ipv6" => nic.private_ipv6_address,
        "subnet" => "default-eu-central-h1",
        "gpu" => nil,
      )
    end

    before do
      nic
    end

    it "returns the VM details by location/name" do
      expect(mcp_tool_data("get_vm", ref: "eu-central-h1/test-vm")).to eq details
    end

    it "returns the VM details by id" do
      expect(mcp_tool_data("get_vm", ref: vm.ubid)).to eq details
    end

    it "works with a token restricted to Vm:view" do
      restrict_pat_to("Vm:view")
      expect(mcp_tool_data("get_vm", ref: "eu-central-h1/test-vm")).to eq details
      expect(mcp_tool_data("get_vm", ref: vm.ubid)).to eq details
    end

    it "returns Forbidden by name and ResourceNotFound by id when the token lacks Vm:view" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_vm", ref: "eu-central-h1/test-vm")).to eq "Forbidden: Sorry, you don't have permission to continue with this request."
      expect(mcp_tool_error("get_vm", ref: vm.ubid)).to start_with "ResourceNotFound: "
    end

    it "rejects a malformed ref and an id of another type" do
      expect(mcp_tool_error("get_vm", ref: "foo")).to eq "InvalidRequest: ref must be location/name or a vm... id"
      expect(mcp_tool_error("get_vm", ref: subnet.ubid)).to eq "InvalidRequest: ref must be location/name or a vm... id"
    end

    it "returns ResourceNotFound for an unknown name or id" do
      expect(mcp_tool_error("get_vm", ref: "eu-central-h1/nope")).to start_with "ResourceNotFound: "
      expect(mcp_tool_error("get_vm", ref: "vm345678901234567890123456")).to start_with "ResourceNotFound: "
    end

    it "returns InvalidLocation for an unknown location" do
      expect(mcp_tool_error("get_vm", ref: "nowhere/test-vm")).to start_with "InvalidLocation: "
    end
  end
end
