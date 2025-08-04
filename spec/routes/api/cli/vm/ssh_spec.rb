# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm ssh" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    @ref = [@vm.display_location, @vm.name].join("/")
    subnet = @project.default_private_subnet(@vm.location)
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "test-nic").subject
    nic.update(vm_id: @vm.id)
  end

  after do
    @socket&.close
  end

  it "provides headers to connect to vm" do
    expect(cli_exec(["vm", @ref, "ssh"])).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "supports swapped arguments" do
    expect(cli_exec(["vm", "ssh", @ref])).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "IPv4 address is used by default if available" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    expect(cli_exec(["vm", @ref, "ssh"])).to eq %w[ssh -- ubi@128.0.0.1]
  end

  it "uses IPv4 address if available and connection is made via IPv4" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET)
    expect(cli_exec(["vm", @ref, "ssh"], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128.0.0.1]
  end

  it "uses IPv6 address if connection is made via IPv6" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET6)
    expect(cli_exec(["vm", @ref, "ssh"], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "-4 option fails if VM has no IPv4 address" do
    expect(cli(["vm", @ref, "-4", "ssh"], status: 400)).to eq "! No valid IPv4 address for requested VM\n"
  end

  it "-4 option uses IPv4 even if connection is made via IPv6" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET6)
    expect(cli_exec(["vm", @ref, "-4", "ssh"], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128.0.0.1]
  end

  it "-6 option uses IPv6 even if connection is made via IPv4" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @socket = UDPSocket.new(Socket::AF_INET)
    expect(cli_exec(["vm", @ref, "-6", "ssh"], env: {"puma.socket" => @socket})).to eq %w[ssh -- ubi@128:1234::2]
  end

  it "-u option overrides user to connect with" do
    expect(cli_exec(["vm", @ref, "-ufoo", "ssh"])).to eq %w[ssh -- foo@128:1234::2]
  end

  it "handles ssh cmd without args" do
    expect(cli_exec(["vm", @ref, "ssh", "id"])).to eq %w[ssh -- ubi@128:1234::2 id]
  end

  it "handles ssh cmd with args" do
    expect(cli_exec(["vm", @ref, "ssh", "uname", "-a"])).to eq %w[ssh -- ubi@128:1234::2 uname -a]
  end

  it "handles ssh cmd with options and without args" do
    expect(cli_exec(["vm", @ref, "ssh", "-A", "--"])).to eq %w[ssh -A -- ubi@128:1234::2]
  end

  it "handles ssh cmd with options and args" do
    expect(cli_exec(["vm", @ref, "ssh", "-A", "--", "uname", "-a"])).to eq %w[ssh -A -- ubi@128:1234::2 uname -a]
  end

  it "handles multiple options" do
    add_ipv4_to_vm(@vm, "128.0.0.1")
    expect(cli_exec(["vm", @ref, "-6u", "foo", "ssh"])).to eq %w[ssh -- foo@128:1234::2]
  end

  it "handles invalid vm reference" do
    expect(cli(["vm", "#{@vm.display_location}/foo", "ssh"], status: 404)).to eq "! Unexpected response status: 404\nDetails: Sorry, we couldn’t find the resource you’re looking for.\n"
    expect(cli(["vm", "foo/#{@vm.name}", "ssh"], status: 404)).to eq "! Unexpected response status: 404\nDetails: Validation failed for following path components: location\n  location: Given location is not a valid location. Available locations: eu-central-h1, eu-north-h1, us-east-a2\n"
    expect(cli(["vm", "#{@vm.display_location}/#{@vm.name}/bar", "ssh"], status: 400)).to start_with "! Invalid vm reference (\"eu-central-h1/test-vm/bar\"), should be in location/vm-name or vm-id format\n"
  end
end
