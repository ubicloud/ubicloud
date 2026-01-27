# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm start" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "restarts vm" do
    expect do
      expect(cli(%w[vm eu-central-h1/test-vm start])).to eq("Scheduled start of VM with id #{@vm.ubid}\n")
    end.to change { Semaphore.where(strand_id: @vm.id, name: "start").count }.from(0).to(1)
  end
end
