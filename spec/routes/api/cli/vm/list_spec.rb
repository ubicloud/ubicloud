# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm list" do
  before do
    @vm = create_vm(project_id: @project.id, ephemeral_net6: "128:1234::0/64")
    add_ipv4_to_vm(@vm, "128.0.0.1")
  end

  it "shows list of vms" do
    expect(cli(%w[vm list])).to eq "eu-central-h1\ttest-vm\t#{@vm.ubid}\t128.0.0.1\t128:1234::2\n"
  end

  it "-i option includes VM ubid" do
    expect(cli(%w[vm list -i])).to eq "#{@vm.ubid}\n"
  end

  it "-n option includes VM name" do
    expect(cli(%w[vm list -n])).to eq "test-vm\n"
  end

  it "-l option includes VM location" do
    expect(cli(%w[vm list -l])).to eq "eu-central-h1\n"
  end

  it "-4 option includes VM IPv4 address" do
    expect(cli(%w[vm list -4])).to eq "128.0.0.1\n"
  end

  it "-6 option includes VM IPv6 address" do
    expect(cli(%w[vm list -6])).to eq "128:1234::2\n"
  end

  it "-4 option includes headers" do
    expect(cli(%w[vm list -h])).to eq "location\tname\tid\tip4\tip6\neu-central-h1\ttest-vm\t#{@vm.ubid}\t128.0.0.1\t128:1234::2\n"
  end

  it "handles multiple options" do
    expect(cli(%w[vm list -inl])).to eq "eu-central-h1\ttest-vm\t#{@vm.ubid}\n"
    expect(cli(%w[vm list -hinl])).to eq "location\tname\tid\neu-central-h1\ttest-vm\t#{@vm.ubid}\n"
  end
end
