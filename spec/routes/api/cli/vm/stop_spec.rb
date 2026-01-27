# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm stop" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "stops vm" do
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm stop])).to eq(<<END)
Scheduled stop of VM with id #{@vm.ubid}.
Note that stopped VMs still accrue billing charges. To stop billing charges,
destroy the VM.
END
    end.to change { Semaphore.where(strand_id: @vm.id, name: "stop").count }.from(0).to(1)
  end
end
