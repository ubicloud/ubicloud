# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AccessControlEntry do
  it "enforces subject, action, and object are valid and related to project" do
    account = Account.create_with_id(email: "test@example.com", status_id: 2)
    project = account.create_project_with_default_policy("Default", default_policy: false)
    project_id = project.id

    ace = described_class.new
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(project_id: ["is not present"], subject_id: ["is not present"])

    ace.project_id = project.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not present"])

    ace.subject_id = account.id
    expect(ace.valid?).to be true

    account2 = Account.create_with_id(email: "test2@example.com", status_id: 2)
    ace.subject_id = account2.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not related to this project"])

    ace.subject_id = ApiKey.create_personal_access_token(account).id
    expect(ace.valid?).to be true

    ace.subject_id = ApiKey.create_personal_access_token(account2).id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not related to this project"])

    project2 = account2.create_project_with_default_policy("Default", default_policy: false)
    ace.subject_id = SubjectTag.create_with_id(project_id: project2.id, name: "V").id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not related to this project"])

    ace.subject_id = SubjectTag.create_with_id(project_id:, name: "V").id
    expect(ace.valid?).to be true

    ace.action_id = ActionType::NAME_MAP["Project:view"]
    expect(ace.valid?).to be true

    ace.action_id = ActionTag.create_with_id(project_id: project2.id, name: "V").id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(action_id: ["is not related to this project"])

    ace.action_id = ActionTag.create_with_id(project_id:, name: "V").id
    expect(ace.valid?).to be true

    ace.object_id = ObjectTag.create_with_id(project_id: project2.id, name: "V").id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    ace.object_id = project2.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    ace.object_id = project.id
    expect(ace.valid?).to be true

    firewall = Firewall.create_with_id(location: "F")
    ace.object_id = firewall.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    firewall.associate_with_project(project)
    expect(ace.valid?).to be true

    ace.object_id = ObjectTag.create_with_id(project_id:, name: "V").id
    expect(ace.valid?).to be true

    ace.subject_id = ace.action_id = ace.object_id
    ace.object_id = described_class.generate_uuid
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(
      subject_id: ["is not related to this project"],
      action_id: ["is not related to this project"],
      object_id: ["is not related to this project"]
    )
  end
end
