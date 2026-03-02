# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm stop" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "stops vm" do
    @vm.update(display_state: "running")
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm stop])).to eq(<<END)
Scheduled stop of VM with id #{@vm.ubid}.
Note that stopped VMs still accrue billing charges. To stop billing charges,
destroy the VM.
END
    end.to change { Semaphore.where(strand_id: @vm.id, name: "stop").count }.from(0).to(1)
  end

  it "raises error if VM is not in the correct state" do
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm stop], status: 400)).to eq "! Unexpected response status: 400\nDetails: The stop action is not supported in the VM's current state\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "stop").count }
  end

  it "raises error if running on AWS" do
    @vm.update(location: Location[name: "us-east-1"])
    expect do
      expect(cli(%w[vm us-east-1/test-vm stop], status: 400)).to eq "! Unexpected response status: 400\nDetails: The stop action is not supported for VMs running on AWS\n"
    end.to not_change { Semaphore.where(strand_id: @vm.id, name: "stop").count }
  end
end
