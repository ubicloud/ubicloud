# frozen_string_literal: true

RSpec.describe Account do
  it "removes referencing access control entries and subject tag memberships" do
    account = described_class.create_with_id(email: "test@example.com")
    project = account.create_project_with_default_policy("project-1", default_policy: false)
    tag = SubjectTag.create_with_id(project_id: project.id, name: "t")
    tag.add_member(account.id)
    ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: account.id)

    account.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end
end
