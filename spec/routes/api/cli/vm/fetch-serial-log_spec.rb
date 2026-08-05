# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm fetch-serial-log" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "requests a fetch" do
    expect {
      expect(cli(%w[vm eu-central-h1/test-vm fetch-serial-log])).to eq("Fetching serial console log, run `show-serial-log` in a few seconds to see the result.\n")
    }.to change { RunCommand.where(vm_id: @vm.id, command: "fetch_serial_log").count }.from(0).to(1)
  end
end
