# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm serial-log" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
    @vm.update(vm_host_id: create_vm_host.id)
  end

  it "requests a fetch and reports it is in progress if none has completed yet" do
    expect {
      expect(cli(%w[vm eu-central-h1/test-vm serial-log])).to eq("Fetching serial console log, run this command again in a few seconds to see the result.\n")
    }.to change { RunCommand.where(vm_id: @vm.id, command: "fetch_serial_log").count }.from(0).to(1)
  end

  it "shows the log if a recent fetch already succeeded" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "succeeded", output: "boot ok", run_at: Time.now)

    expect(cli(%w[vm eu-central-h1/test-vm serial-log])).to eq("boot ok\n")
  end

  it "shows the error if a recent fetch failed" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "failed", output: nil, run_at: Time.now)

    expect(cli(%w[vm eu-central-h1/test-vm serial-log])).to eq("Failed to fetch serial console log.\n")
  end

  it "does not request another fetch shortly after a successful one, unless refresh is passed" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "succeeded", output: "boot ok", run_at: Time.now)

    expect {
      cli(%w[vm eu-central-h1/test-vm serial-log -r])
    }.not_to change { RunCommand.where(vm_id: @vm.id, command: "fetch_serial_log").count }
  end

  it "requests a new fetch with --refresh once the cooldown has passed" do
    RunCommand.create(vm_id: @vm.id, command: "fetch_serial_log", status: "succeeded", output: "boot ok", run_at: Time.now - 61)

    expect(cli(%w[vm eu-central-h1/test-vm serial-log --refresh])).to eq("Fetching serial console log, run this command again in a few seconds to see the result.\n")
    expect(RunCommand.where(vm_id: @vm.id, command: "fetch_serial_log").first.status).to eq "created"
  end
end
