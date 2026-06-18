# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vm serial-log" do
  before do
    @vm = create_vm(project_id: @project.id)
    @ref = [@vm.display_location, @vm.name].join("/")
  end

  it "prints the serial console tail" do
    expect_any_instance_of(Vm).to receive(:serial_log).and_return("boot ok\n")
    expect(cli(%W[vm #{@ref} serial-log])).to eq("boot ok\n")
  end

  it "fails for non-metal VMs" do
    @vm.update(location_id: Location[name: "us-east-1"].id)
    @ref = [@vm.display_location, @vm.name].join("/")
    expect(cli(%W[vm #{@ref} serial-log], status: 400))
      .to eq("! Unexpected response status: 400\nDetails: Serial log is not available for VMs running on us-east-1\n")
  end
end
