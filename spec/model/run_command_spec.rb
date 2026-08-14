# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe RunCommand do
  subject(:rc) { described_class.create(vm_id: create_vm.id, command: "fetch_serial_log") }

  it "reports succeeded? only when status is succeeded" do
    expect(rc.succeeded?).to be false
    rc.update(status: "succeeded")
    expect(rc.succeeded?).to be true
    expect(rc.done?).to be true
  end

  it "reports failed? only when status is failed" do
    expect(rc.failed?).to be false
    rc.update(status: "failed")
    expect(rc.failed?).to be true
    expect(rc.done?).to be true
  end

  it "is not done while status is created" do
    expect(rc.done?).to be false
  end

  it "truncates output to the last MAX_OUTPUT_BYTES bytes" do
    rc.update(output: "a" * (RunCommand::MAX_OUTPUT_BYTES + 10) + "tail")
    expect(rc.output.bytesize).to eq(RunCommand::MAX_OUTPUT_BYTES)
    expect(rc.output).to end_with("tail")
  end

  it "scrubs invalid UTF-8 byte sequences from output, e.g. from truncating mid-character" do
    rc.update(output: "before\xFF\xFEafter".dup.force_encoding("BINARY"))
    expect(rc.output.valid_encoding?).to be true
    expect(rc.output).to include("before")
    expect(rc.output).to include("after")
  end

  it "leaves output nil when set to nil" do
    rc.update(output: nil)
    expect(rc.output).to be_nil
  end
end
