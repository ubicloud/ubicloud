# frozen_string_literal: true

RSpec.describe Account do
  let(:account) { described_class.create(email: "test@example.com") }

  it "removes referencing access control entries and subject tag memberships" do
    project = account.create_project_with_default_policy("project-1", default_policy: false)
    tag = SubjectTag.create(project_id: project.id, name: "t")
    tag.add_member(account.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: account.id)

    account.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end
end
