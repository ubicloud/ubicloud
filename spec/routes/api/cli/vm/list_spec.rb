# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm list" do
  id_headr = "id" + " " * 24

  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    add_ipv4_to_vm(@vm, "128.0.0.1")
  end

  it "shows list of vms" do
    expect(cli(%w[vm list -N])).to eq "eu-central-h1  test-vm  #{@vm.ubid}  128.0.0.1  128:1234::2\n"
  end

  it "-f id option includes VM ubid" do
    expect(cli(%w[vm list -Nfid])).to eq "#{@vm.ubid}\n"
  end

  it "-f name option includes VM name" do
    expect(cli(%w[vm list -Nfname])).to eq "test-vm\n"
  end

  it "-f location option includes VM location" do
    expect(cli(%w[vm list -Nflocation])).to eq "eu-central-h1\n"
  end

  it "-f ip4 option includes VM IPv4 address" do
    expect(cli(%w[vm list -Nfip4])).to eq "128.0.0.1\n"
  end

  it "-f ip6 option includes VM IPv6 address" do
    expect(cli(%w[vm list -Nfip6])).to eq "128:1234::2\n"
  end

  it "-l option filters to specific location" do
    expect(cli(%w[vm list -Nleu-central-h1])).to eq "eu-central-h1  test-vm  #{@vm.ubid}  128.0.0.1  128:1234::2\n"
    expect(cli(%w[vm list -Nleu-north-h1])).to eq "\n"
  end

  it "headers are shown by default" do
    expect(cli(%w[vm list])).to eq <<~END
      location       name     #{id_headr}  ip4        ip6        
      eu-central-h1  test-vm  #{@vm.ubid}  128.0.0.1  128:1234::2
    END
  end

  it "handles case where header size is larger than largest column size" do
    @vm.update(name: "Abc")
    expect(cli(%w[vm list])).to eq <<~END
      location       name  #{id_headr}  ip4        ip6        
      eu-central-h1  Abc   #{@vm.ubid}  128.0.0.1  128:1234::2
    END
  end

  it "handles multiple options" do
    expect(cli(%w[vm list -Nflocation,name,id])).to eq "eu-central-h1  test-vm  #{@vm.ubid}\n"
    expect(cli(%w[vm list -flocation,name,id])).to eq <<~END
      location       name     #{id_headr}
      eu-central-h1  test-vm  #{@vm.ubid}
    END
  end

  it "shows error for empty fields" do
    expect(cli(%w[vm list -Nf] + [""], status: 400)).to start_with "! No fields given in vm list -f option\n"
  end

  it "shows error for duplicate fields" do
    expect(cli(%w[vm list -Nfid,id], status: 400)).to start_with "! Duplicate field(s) in vm list -f option\n"
  end

  it "shows error for invalid fields" do
    expect(cli(%w[vm list -Nffoo], status: 400)).to start_with "! Invalid field(s) given in vm list -f option: foo\n"
  end

  it "shows error for invalid location" do
    expect(cli(%w[vm list -Nleu-/-h1], status: 400)).to start_with "! Invalid location provided in vm list -l option\n"
  end
end
