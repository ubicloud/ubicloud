# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vi update" do
  it "updates virtual machine init script" do
    cli(%w[vi vis create] << "a a")
    vm_init_script = VmInitScript.first
    expect(vm_init_script.name).to eq "vis"
    expect(vm_init_script.script).to eq "a a"
    body = cli(%w[vi vis update] << "b b")
    vm_init_script.reload
    expect(vm_init_script.name).to eq "vis"
    expect(vm_init_script.script).to eq "b b"
    expect(body).to eq "Virtual machine init script with id #{vm_init_script.ubid} updated\n"
  end
end
