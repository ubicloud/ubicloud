# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm scp" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    @ref = [@vm.display_location, @vm.name].join("/")
    subnet = @project.default_private_subnet(@vm.location)
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "test-nic").subject
    nic.update(vm_id: @vm.id)
  end

  it "provides headers to copy local file to remote" do
    expect(cli_exec(["vm", @ref, "scp", "local", ":remote"])).to eq %w[scp -- local ubi@[128:1234::2]:remote]
  end

  it "IPv4 address is used by default if available" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    expect(cli_exec(["vm", @ref, "scp", "local", ":remote"])).to eq %w[scp -- local ubi@128.0.0.1:remote]
  end

  it "provides headers to copy remote file to local" do
    expect(cli_exec(["vm", @ref, "scp", ":remote", "local"])).to eq %w[scp -- ubi@[128:1234::2]:remote local]
  end

  it "supports scp options" do
    expect(cli_exec(["vm", @ref, "scp", "-A", ":remote", "local"])).to eq %w[scp -A -- ubi@[128:1234::2]:remote local]
  end

  it "returns error if both files are local" do
    expect(cli(["vm", @ref, "scp", "local", "local"], status: 400)).to eq "! Only one path should be remote (start with ':')\n"
  end

  it "returns error if both files are remote" do
    expect(cli(["vm", @ref, "scp", ":remote", ":remote"], status: 400)).to eq "! Only one path should be remote (start with ':')\n"
  end
end
