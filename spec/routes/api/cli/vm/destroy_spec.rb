# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm destroy" do
  it "destroys vm" do
    expect(Vm.count).to eq 0
    expect(PrivateSubnet.count).to eq 0
    cli(%w[vm eu-central-h1/test-vm create a])
    expect(Vm.count).to eq 1
    vm = Vm.first
    expect(vm).to be_a Vm
    expect(Semaphore.where(strand_id: vm.id, name: "destroy")).to be_empty
    expect(cli(%w[vm eu-central-h1/test-vm destroy])).to eq "VM, if it exists, is now scheduled for destruction"
    expect(Semaphore.where(strand_id: vm.id, name: "destroy")).not_to be_empty
  end
end
