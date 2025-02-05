# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm list" do
  id_headr = "id" + " " * 24

  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    add_ipv4_to_vm(@vm, "128.0.0.1")
  end

  it "shows list of vms" do
    expect(cli(%w[vm list -N])).to eq "eu-central-h1 test-vm #{@vm.ubid} 128.0.0.1 128:1234::2\n"
  end

  it "-i option includes VM ubid" do
    expect(cli(%w[vm list -Ni])).to eq "#{@vm.ubid}\n"
  end

  it "-n option includes VM name" do
    expect(cli(%w[vm list -Nn])).to eq "test-vm\n"
  end

  it "-l option includes VM location" do
    expect(cli(%w[vm list -Nl])).to eq "eu-central-h1\n"
  end

  it "-4 option includes VM IPv4 address" do
    expect(cli(%w[vm list -N4])).to eq "128.0.0.1\n"
  end

  it "-6 option includes VM IPv6 address" do
    expect(cli(%w[vm list -N6])).to eq "128:1234::2\n"
  end

  it "headers are shown by default" do
    expect(cli(%w[vm list])).to eq <<~END
      location      name    #{id_headr} ip4       ip6        
      eu-central-h1 test-vm #{@vm.ubid} 128.0.0.1 128:1234::2
    END
  end

  it "handles multiple options" do
    expect(cli(%w[vm list -Ninl])).to eq "eu-central-h1 test-vm #{@vm.ubid}\n"
    expect(cli(%w[vm list -inl])).to eq <<~END
      location      name    #{id_headr}
      eu-central-h1 test-vm #{@vm.ubid}
    END
  end
end
