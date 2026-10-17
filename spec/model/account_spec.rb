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
    ApiKey.create_personal_access_token(account, project:)
    DB[:account_active_session_keys].insert(account_id: account.id, session_id: "session-id")
    project.update(billing_info_id: BillingInfo.create(stripe_id: "cus123").id)
    payment_method = project.billing_info.add_payment_method(stripe_id: "pm123")
    project.add_invitation(inviter_id: account.id, email: "test2@example.com", expires_at: now + 60 * 60)
    expect { account.suspend }
      .to change(account, :suspended_at).from(nil).to(now)
      .and change { DB[:account_active_session_keys].where(account_id: account.id).count }.from(1).to(0)
      .and change { payment_method.reload.fraud }.from(false).to(true)
      .and change { project.invitations_dataset.count }.from(1).to(0)
    expect(Mail::TestMailer.deliveries.length).to eq 1
    mail = Mail::TestMailer.deliveries.first
    expect(mail.to).to eq ["test@example.com"]
    expect(mail.subject).to eq "Your Ubicloud account has been suspended"
    expect(mail.text_part.body.decoded).to include("unusual activity")
  end

  it "suspend sends unpaid invoice email when account has unpaid invoices" do
    project = account.create_project_with_default_policy("project-1")
    Invoice.create(project_id: project.id, invoice_number: "1", begin_time: Time.now, end_time: Time.now, content: {}, status: "doubtful")
    account.suspend
    expect(Mail::TestMailer.deliveries.length).to eq 1
    body = Mail::TestMailer.deliveries.first.text_part.body.decoded
    expect(body).to include("unpaid invoices")
    expect(body).not_to include("unusual activity")
  end

  it "suspend does not send email when send_email is false" do
    account.suspend(send_email: false)
    expect(account.suspended_at).not_to be_nil
    expect(Mail::TestMailer.deliveries).to be_empty
  end

  it "unsuspend" do
    project = account.create_project_with_default_policy("project-1")
    project.update(billing_info_id: BillingInfo.create(stripe_id: "cus123").id)
    payment_method = project.billing_info.add_payment_method(stripe_id: "pm123")
    payment_method.update(fraud: true)
    account.update(suspended_at: Time.now)
    expect { account.unsuspend }
      .to change(account, :suspended_at).to(nil)
      .and change { payment_method.reload.fraud }.from(true).to(false)
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
