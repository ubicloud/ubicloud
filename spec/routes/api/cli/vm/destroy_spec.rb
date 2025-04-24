# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm destroy" do
  before do
    expect(Vm.count).to eq 0
    expect(PrivateSubnet.count).to eq 0
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    expect(Vm.count).to eq 1
    @vm = Vm.first
    expect(@vm).to be_a Vm
  end

  it "destroys vm directly if -f option is given" do
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).to be_empty
    expect(cli(%w[vm eu-central-h1/test-vm destroy -f])).to eq "Virtual machine, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).not_to be_empty
  end

  it "asks for confirmation if -f option is not given" do
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).to be_empty
    expect(cli(%w[vm eu-central-h1/test-vm destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this virtual machine is not recoverable.
      Enter the following to confirm destruction of the virtual machine: #{@vm.name}
    END
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).to be_empty
  end

  it "works on correct confirmation" do
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).to be_empty
    expect(cli(%w[--confirm test-vm vm eu-central-h1/test-vm destroy])).to eq "Virtual machine, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).not_to be_empty
  end

  it "fails on incorrect confirmation" do
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).to be_empty
    expect(cli(%w[--confirm foo vm eu-central-h1/test-vm destroy], status: 400)).to eq "! Confirmation of virtual machine name not successful.\n"
    expect(Semaphore.where(strand_id: @vm.id, name: "destroy")).to be_empty
  end
end
