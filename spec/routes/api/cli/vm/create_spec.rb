# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm create" do
  it "creates vm with no options" do
    expect(Vm.count).to eq 0
    expect(PrivateSubnet.count).to eq 0
    body = cli(%w[vm eu-central-h1/test-vm create a])
    expect(Vm.count).to eq 1
    expect(PrivateSubnet.count).to eq 1
    vm = Vm.first
    expect(vm).to be_a Vm
    ps = PrivateSubnet.first
    expect(ps).to be_a PrivateSubnet
    expect(vm.name).to eq "test-vm"
    expect(vm.public_key).to eq "a"
    expect(vm.display_location).to eq "eu-central-h1"
    expect(vm.display_size).to eq "standard-2"
    expect(vm.boot_image).to eq Config.default_boot_image_name
    expect(vm.ip4_enabled).to be true
    expect(vm.strand.stack[0]["storage_volumes"][0]["size_gib"]).to eq 40
    expect(vm.nics.first.private_subnet_id).to eq ps.id
    expect(body).to eq "VM created with id: #{vm.ubid}"
  end

  it "creates vm with all options" do
    expect(Vm.count).to eq 0
    ps = PrivateSubnet.create(project_id: @project.id, name: "test-ps", location: "hetzner-hel1", net6: "fe80::/64", net4: "192.168.0.0/24")
    body = cli(%W[vm eu-north-h1/test-vm2 create -6 -b debian-12 -u foo -s standard-4 -S 80 -p #{ps.ubid} b])
    vm = Vm.first
    expect(Vm.count).to eq 1
    expect(PrivateSubnet.count).to eq 1
    expect(vm).to be_a Vm
    expect(vm.name).to eq "test-vm2"
    expect(vm.public_key).to eq "b"
    expect(vm.display_location).to eq "eu-north-h1"
    expect(vm.display_size).to eq "standard-4"
    expect(vm.boot_image).to eq "debian-12"
    expect(vm.ip4_enabled).to be false
    expect(vm.strand.stack[0]["storage_volumes"][0]["size_gib"]).to eq 80
    expect(vm.nics.first.private_subnet_id).to eq ps.id
    expect(body).to eq "VM created with id: #{vm.ubid}"
  end

  it "translates LF to CRLF in public keys to work with multiple public keys" do
    body = cli(%w[vm eu-north-h1/test-vm2 create] << "a\nb")
    vm = Vm.first
    expect(vm.public_key).to eq "a\r\nb"
    expect(body).to eq "VM created with id: #{vm.ubid}"
  end

  it "shows errors if trying to create a vm with an invalid private subnet" do
    expect(Vm.count).to eq 0
    ps = PrivateSubnet.create(project_id: @project.id, name: "test-ps", location: "hetzner-fsn1", net6: "fe80::/64", net4: "192.168.0.0/24")
    expect(cli(%W[vm eu-north-h1/test-vm2 create -p #{ps.ubid} c], status: 400)).to eq(<<~END.chomp)
      ! Unexpected response status: 400
      Details: Validation failed for following fields: private_subnet_id
        private_subnet_id: Private subnet with the given id "#{ps.ubid}" is not found in the location "eu-north-h1"
    END
    expect(Vm.count).to eq 0
  end

  it "shows errors if trying to create a vm with an invalid number of arguments" do
    expect(Vm.count).to eq 0
    expect(cli(%W[vm eu-north-h1/test-vm2 create], status: 400).b).to start_with("! Invalid arguments for vm create subcommand (public_key is required)")
    expect(cli(%W[vm eu-north-h1/test-vm2 create c d], status: 400).b).to start_with("! Invalid arguments for vm create subcommand (public_key is required)")
    expect(Vm.count).to eq 0
  end
end
