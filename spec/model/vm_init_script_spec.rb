# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmInitScript do
  it "implements a max length validation on the init_script column" do
    vm = described_class.new(init_script: "a" * 2001)
    expect(vm.valid?).to be false
    vm.init_script = "a" * 2000
    expect(vm.valid?).to be true
  end

  it "returns the init_script as UTF-8" do
    vm = Prog::Vm::Nexus.assemble("k y", Project.create(name: "test").id).subject
    described_class.create_with_id(vm, init_script: "echo 'héllo'")

    init_script = described_class[vm.id].init_script
    expect(init_script.encoding).to eq Encoding::UTF_8
    expect(init_script).to eq "echo 'héllo'"
  end
end
