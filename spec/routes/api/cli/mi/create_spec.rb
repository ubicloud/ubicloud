# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli mi create" do
  before do
    @vm = Prog::Vm::Nexus.assemble("dummy-public key", @project.id, name: "test-vm", location_id: Location::HETZNER_FSN1_ID).subject
    @vm.strand.update(label: "stopped")
  end

  it "creates machine image" do
    count_before = MachineImage.count
    body = cli(%W[mi eu-central-h1/test-mi create -v #{@vm.ubid}])
    expect(MachineImage.count).to eq count_before + 1
    mi = MachineImage.first(name: "test-mi")
    expect(mi.name).to eq "test-mi"
    expect(body).to eq "Machine image created with id: #{mi.ubid}\n"
  end

  it "creates machine image with description" do
    count_before = MachineImage.count
    body = cli(%W[mi eu-central-h1/test-mi create -v #{@vm.ubid} -d my-desc])
    expect(MachineImage.count).to eq count_before + 1
    mi = MachineImage.first(name: "test-mi")
    expect(mi.name).to eq "test-mi"
    expect(mi.description).to eq "my-desc"
    expect(body).to eq "Machine image created with id: #{mi.ubid}\n"
  end

  it "fails without vm-id" do
    body = cli(%w[mi eu-central-h1/test-mi create], status: 400)
    expect(body).to include("Vm-id is required")
  end
end
