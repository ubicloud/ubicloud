# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe SubjectTag do
  let(:project) { Project.create(name: "test") }

  describe ".valid_member?" do
    it "accepts a VM in the project as a subject (managed identities)" do
      vm = create_vm(project_id: project.id)
      expect(described_class.valid_member?(project.id, vm)).to be true
    end

    it "rejects a VM that belongs to a different project" do
      other_project = Project.create(name: "other")
      vm = create_vm(project_id: other_project.id)
      expect(described_class.valid_member?(project.id, vm)).to be false
    end
  end

  describe "#check_members_to_add" do
    it "allows adding an in-project VM as a tag member, but not a cross-project VM" do
      tag = described_class.create(project_id: project.id, name: "Identities")
      vm = create_vm(project_id: project.id)
      other_vm = create_vm(project_id: Project.create(name: "other").id)

      to_add, issues = tag.check_members_to_add([vm.id, other_vm.id])
      expect(to_add).to eq([vm.id])
      expect(issues).to eq(["1 members not valid"])
    end
  end

  it "authorizes a VM subject through both direct and tag-based access control entries" do
    vm = create_vm(project_id: project.id, name: "identity-vm")
    object = create_vm(project_id: project.id, name: "target-vm")

    # No grants yet: the VM identity can do nothing.
    expect(Authorization.has_permission?(project.id, vm.id, "Vm:view", object.id)).to be false

    # Direct grant to the VM subject.
    ace = AccessControlEntry.create(project_id: project.id, subject_id: vm.id, action_id: ActionType::NAME_MAP["Vm:view"])
    expect(Authorization.has_permission?(project.id, vm.id, "Vm:view", object.id)).to be true
    expect(Authorization.has_permission?(project.id, vm.id, "Vm:delete", object.id)).to be false
    ace.destroy

    # Grant via a subject tag the VM is a member of ("identity bucket").
    tag = described_class.create(project_id: project.id, name: "Identities")
    tag.add_subject(vm.id)
    AccessControlEntry.create(project_id: project.id, subject_id: tag.id, action_id: ActionType::NAME_MAP["Vm:view"])
    expect(Authorization.has_permission?(project.id, vm.id, "Vm:view", object.id)).to be true
  end
end
