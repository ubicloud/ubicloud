# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vi create" do
  it "creates virtual machine init script" do
    expect(VmInitScript.count).to eq 0
    body = cli(%w[vi vis create] << "a a")
    expect(VmInitScript.count).to eq 1
    vm_init_script = VmInitScript.first
    expect(vm_init_script.name).to eq "vis"
    expect(vm_init_script.script).to eq "a a"
    expect(body).to eq "Virtual machine init script registered with id: #{vm_init_script.ubid}\n"
  end
end
