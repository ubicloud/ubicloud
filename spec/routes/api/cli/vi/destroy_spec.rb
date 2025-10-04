# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli vi destroy" do
  before do
    cli(%w[vi vis create] << "a a")
    @vm_init_script = VmInitScript.first
  end

  it "destroys virtual machine init script directly if -f option is given" do
    expect(cli(%w[vi vis destroy -f])).to eq "Virtual machine init script has been removed\n"
    expect(@vm_init_script).not_to be_exist
  end

  it "asks for confirmation if -f option is not given" do
    expect(cli(%w[vi vis destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this virtual machine init script is not recoverable.
      Enter the following to confirm destruction of the virtual machine init script: #{@vm_init_script.name}
    END
    expect(@vm_init_script).to be_exist
  end

  it "works on correct confirmation" do
    expect(cli(%w[--confirm vis vi vis destroy])).to eq "Virtual machine init script has been removed\n"
    expect(@vm_init_script).not_to be_exist
  end

  it "fails on incorrect confirmation" do
    expect(cli(%w[--confirm foo vi vis destroy], status: 400)).to eq "! Confirmation of virtual machine init script name not successful.\n"
    expect(@vm_init_script).to be_exist
  end
end
