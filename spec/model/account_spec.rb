# frozen_string_literal: true

RSpec.describe Account do
  let(:account) { described_class.create_with_id(email: "test@example.com") }

  it "removes referencing access control entries and subject tag memberships" do
    project = account.create_project_with_default_policy("project-1", default_policy: false)
    tag = SubjectTag.create_with_id(project_id: project.id, name: "t")
    tag.add_member(account.id)
    ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: account.id)

    account.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end

  it "hyper_tag_name" do
    expect(account.hyper_tag_name).to eq("user/test@example.com")
  end

  it "hyper_tag, associate, and dissociate with project methods" do
    project = Project.create_with_id(name: "test")
    expect(account.hyper_tag(project)).to be_nil

    account.associate_with_project(project)
    expect(account.hyper_tag(project)).to exist

    account.dissociate_with_project(project)
    expect(account.hyper_tag(project)).to be_nil
  end

  it "does not associate/dissociate with nil project" do
    expect(account.associate_with_project(nil)).to be_nil
    expect(account.dissociate_with_project(nil)).to be_nil
  end
end
