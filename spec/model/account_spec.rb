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

  describe ".create_project_with_default_policy" do
    it "sets reputation new" do
      project = account.create_project_with_default_policy("project-2")
      expect(project.reputation).to eq("new")
    end

    it "sets reputation limited if the email is from gmail" do
      account.email = "test@gmail.com"
      project = account.create_project_with_default_policy("project-2")
      expect(project.reputation).to eq("limited")
    end

    it "sets reputation new if the email is from gmail but has a verified project already" do
      account.email = "test@gmail.com"
      account.add_project(Project.create(name: "project-3", reputation: "verified"))
      project = account.create_project_with_default_policy("project-2")
      expect(project.reputation).to eq("new")
    end
  end
end
