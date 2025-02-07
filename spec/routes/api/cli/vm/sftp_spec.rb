# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm sftp" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    @ref = [@vm.display_location, @vm.name].join("/")
    subnet = @project.default_private_subnet(@vm.location)
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "test-nic").subject
    nic.update(vm_id: @vm.id)
  end

  it "provides headers to connect to vm via sftp" do
    expect(cli_exec(["vm", @ref, "sftp"])).to eq %w[sftp -- ubi@[128:1234::2]]
  end

  it "IPv4 address is used by default if available" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    expect(cli_exec(["vm", @ref, "sftp"])).to eq %w[sftp -- ubi@128.0.0.1]
  end

  it "supports sftp options" do
    expect(cli_exec(["vm", @ref, "sftp", "-A"])).to eq %w[sftp -A -- ubi@[128:1234::2]]
  end
end
