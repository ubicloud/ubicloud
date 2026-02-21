# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi create" do
  it "creates machine image from stopped VM" do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", @project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
    vm.strand.update(label: "stopped")

    expect(MachineImage.count).to eq 0
    body = cli(["mi", "eu-central-h1/test-image", "create", "-v", vm.ubid])
    expect(MachineImage.count).to eq 1
    mi = MachineImage.first
    expect(mi.name).to eq "test-image"
    expect(body).to eq "Machine image created with id: #{mi.ubid}\n"
  end

  it "creates machine image with description" do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", @project.id, name: "stopped-vm", location_id: Location::HETZNER_FSN1_ID).subject
    vm.strand.update(label: "stopped")

    body = cli(["mi", "eu-central-h1/test-image", "create", "-v", vm.ubid, "-d", "my description"])
    mi = MachineImage.first
    expect(mi.description).to eq "my description"
    expect(body).to eq "Machine image created with id: #{mi.ubid}\n"
  end
end
