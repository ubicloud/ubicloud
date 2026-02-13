# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm restart" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "restarts vm" do
    expect(Semaphore.where(strand_id: @vm.id, name: "restart")).to be_empty
    expect(cli(%w[vm eu-central-h1/test-vm restart])).to eq "Scheduled restart of VM with id #{@vm.ubid}\n"
    expect(Semaphore.where(strand_id: @vm.id, name: "restart")).not_to be_empty
  end
end
