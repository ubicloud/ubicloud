# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm start" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "restarts vm" do
    @vm.strand.update(label: "stopped")
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm start])).to eq("Scheduled start of VM with id #{@vm.ubid}\n")
    end.to change { Semaphore.where(strand_id: @vm.id, name: "start").count }.from(0).to(1)
  end

  it "raises error if VM is not in the correct state" do
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm start], status: 400)).to eq "! Unexpected response status: 400\nDetails: The start action is not supported in the VM's current state\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "start").count }
  end

  it "raises error if running on AWS" do
    @vm.update(location: Location[name: "us-east-1"])
    expect do
      expect(cli(%w[vm us-east-1/test-vm start], status: 400)).to eq "! Unexpected response status: 400\nDetails: The start action is not supported for VMs running on AWS\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "start").count }
  end
end
