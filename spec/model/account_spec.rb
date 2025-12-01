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

  it "suspend" do
    now = Time.now
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    project = account.create_project_with_default_policy("project-1")
    ApiKey.create_personal_access_token(account, project: project)
    DB[:account_active_session_keys].insert(account_id: account.id, session_id: "session-id")
    project.update(billing_info_id: BillingInfo.create(stripe_id: "cus123").id)
    payment_method = project.billing_info.add_payment_method(stripe_id: "pm123")
    project.add_invitation(inviter_id: account.id, email: "test2@example.com", expires_at: now + 60 * 60)
    expect { account.suspend }
      .to change(account, :suspended_at).from(nil).to(now)
      .and change { DB[:account_active_session_keys].where(account_id: account.id).count }.from(1).to(0)
      .and change { payment_method.reload.fraud }.from(false).to(true)
      .and change { project.invitations_dataset.count }.from(1).to(0)
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
