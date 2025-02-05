# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm ssh" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    subnet = @project.default_private_subnet(@vm.location)
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "test-nic").subject
    nic.update(vm_id: @vm.id)
  end

  after do
    @socket&.close
  end

  it "provides headers to connect to vm" do
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name])).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "IPv4 address is used by default if available" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name])).to eq %w[ssh -- ubi@128.0.0.1]
  end

  it "uses IPv4 address if available and connection is made via IPv4" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET)
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128.0.0.1]
  end

  it "uses IPv6 address if connection is made via IPv6" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET6)
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "-4 option fails if VM has no IPv4 address" do
    expect(cli(["vm", "ssh", "-4", @vm.display_location, @vm.name], status: 400)).to eq "No valid IPv4 address for requested VM"
  end

  it "-4 option uses IPv4 even if connection is made via IPv6" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET6)
    expect(cli_exec(["vm", "ssh", "-4", @vm.display_location, @vm.name], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128.0.0.1]
  end

  it "-6 option uses IPv6 even if connection is made via IPv4" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET)
    expect(cli_exec(["vm", "ssh", "-6", @vm.display_location, @vm.name], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "-u option overrides user to connect with" do
    expect(cli_exec(["vm", "ssh", "-ufoo", @vm.display_location, @vm.name])).to eq %w[ssh -- foo@128:1234::2]
  end

  it "handles ssh cmd without args" do
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name, "id"])).to eq %w[ssh -- ubi@128:1234::2 id]
  end

  it "handles ssh cmd with args" do
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name, "uname", "-a"])).to eq %w[ssh -- ubi@128:1234::2 uname -a]
  end

  it "handles ssh cmd with options and without args" do
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name, "-A", "--"])).to eq %w[ssh -A -- ubi@128:1234::2]
  end

  it "handles ssh cmd with options and args" do
    expect(cli_exec(["vm", "ssh", @vm.display_location, @vm.name, "-A", "--", "uname", "-a"])).to eq %w[ssh -A -- ubi@128:1234::2 uname -a]
  end

  it "handles multiple options" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    expect(cli_exec(["vm", "ssh", "-6u", "foo", @vm.display_location, @vm.name])).to eq %w[ssh -- foo@128:1234::2]
  end

  it "handles invalid location or name" do
    expect(cli(["vm", "ssh", "-4", @vm.display_location, "foo"], status: 404)).to eq "Error: unexpected response status: 404\nDetails: Sorry, we couldn’t find the resource you’re looking for."
    expect(cli(["vm", "ssh", "-4", "foo", @vm.name], status: 404)).to eq "Error: unexpected response status: 404\nDetails: Sorry, we couldn’t find the resource you’re looking for."
  end
end
