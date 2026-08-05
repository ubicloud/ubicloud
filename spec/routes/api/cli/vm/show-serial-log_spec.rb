# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm show-serial-log" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "reports that no log has been fetched yet" do
    expect(cli(%w[vm eu-central-h1/test-vm show-serial-log])).to eq("No serial console log has been fetched yet. Run `fetch-serial-log` first.\n")
  end

  it "reports that a fetch is in progress" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "created")

    expect(cli(%w[vm eu-central-h1/test-vm show-serial-log])).to eq("Fetching serial console log, run this command again in a few seconds to see the result.\n")
  end

  it "shows the log if a recent fetch already succeeded" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "succeeded", output: "boot ok", run_at: Time.now)

    expect(cli(%w[vm eu-central-h1/test-vm show-serial-log])).to eq("boot ok\n")
  end

  it "shows the error if a recent fetch failed" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "failed", output: "no route to host", run_at: Time.now)

    expect(cli(%w[vm eu-central-h1/test-vm show-serial-log])).to eq("Failed to fetch serial console log: no route to host\n")
  end
end
