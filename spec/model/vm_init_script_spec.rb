# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmInitScript do
  it "implements a max length validation on the init_script column" do
    vm = described_class.new(script: "a", init_script: "a" * 2001)
    expect(vm.valid?).to be false
    vm.init_script = "a" * 2000
    expect(vm.valid?).to be true
  end

  it ".populate_encrypted_column populates the encrypted column for existing entries without values" do
    project_id = Project.create(name: "test").id
    vm1 = Prog::Vm::Nexus.assemble("a a", project_id)
    vm2 = Prog::Vm::Nexus.assemble("a a", project_id)
    vmis_id = described_class.insert(id: vm1.id, script: "a")
    vmis2 = described_class.create_with_id(vm2, script: "b", init_script: "c")
    described_class.populate_encrypted_column
    expect(described_class[vmis_id].init_script).to eq "a"
    expect(vmis2.reload.init_script).to eq "c"
  end
end
