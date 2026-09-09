# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm set-maintenance-window" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
  end

  it "sets or unsets maintenance window" do
    expect(@vm.maintenance_window_start_at).to be_nil
    expect(cli(%w[vm eu-central-h1/test-vm set-maintenance-window 22])).to eq "Starting hour for maintenance window for virtual machine with id #{@vm.ubid} set to 22.\n"
    expect(@vm.reload.maintenance_window_start_at).to eq 22
    expect(cli(%w[vm eu-central-h1/test-vm set-maintenance-window] << "")).to eq "Unset maintenance window for virtual machine with id #{@vm.ubid}.\n"
    expect(@vm.reload.maintenance_window_start_at).to be_nil
  end

  it "sets days" do
    expect(cli(%w[vm eu-central-h1/test-vm set-maintenance-window -d mon,wed 22])).to eq "Starting hour for maintenance window for virtual machine with id #{@vm.ubid} set to 22 on mon, wed.\n"
    @vm.reload
    expect(@vm.maintenance_window_start_at).to eq 22
    expect(@vm.maintenance_window_day_names).to eq(["mon", "wed"])
  end

  it "unsets days while keeping the start hour" do
    cli(%w[vm eu-central-h1/test-vm set-maintenance-window -d mon,wed 22])
    expect(@vm.reload.maintenance_window_day_names).to eq(["mon", "wed"])

    expect(cli(%w[vm eu-central-h1/test-vm set-maintenance-window -d] << "" << "22")).to eq "Starting hour for maintenance window for virtual machine with id #{@vm.ubid} set to 22.\n"
    @vm.reload
    expect(@vm.maintenance_window_start_at).to eq 22
    expect(@vm.maintenance_window_day_names).to eq([])
  end
end
