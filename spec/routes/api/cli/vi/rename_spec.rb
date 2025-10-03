# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vi rename" do
  it "renames virtual machine init script" do
    cli(%w[vi vis create] << "a a")
    vm_init_script = VmInitScript.first
    expect(vm_init_script.name).to eq "vis"
    expect(vm_init_script.script).to eq "a a"
    body = cli(%w[vi vis rename b])
    vm_init_script.reload
    expect(vm_init_script.name).to eq "b"
    expect(vm_init_script.script).to eq "a a"
    expect(body).to eq "Virtual machine init script with id #{vm_init_script.ubid} renamed to b\n"
  end
end
