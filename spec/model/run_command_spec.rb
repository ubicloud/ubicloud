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
end
