# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::Nexus do
  it "creates the user and key record" do
    st = described_class.assemble("some_ssh_key")
    vm = Vm[st.id]
    vm.update(ephemeral_net6: "fe80::/64")

    expect(vm.unix_user).to eq("ubi")
    expect(vm.public_key).to eq("some_ssh_key")

    prog = described_class.new(st)
    sshable = instance_double(Sshable)
    vmh = instance_double(VmHost, sshable: sshable)

    expect(sshable).to receive(:cmd).with("sudo bin/prepvm.rb #{prog.q_vm} fe80::/64 ubi some_ssh_key")
    expect(st).to receive(:load).and_return(prog)
    expect(prog).to receive(:host).and_return(vmh)

    st.update(label: "prep")
    st.run
  end
end
