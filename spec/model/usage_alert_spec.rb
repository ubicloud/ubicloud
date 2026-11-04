# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UsageAlert do
  let(:project) { Project.create(name: "project1") }
  let(:user) { Account.create(email: "user@example.com", name: "User1") }

  it "trigger sends email and updates last_triggered_at" do
    now = Time.now.round
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    last_triggered_at = now - 42 * 24 * 60 * 60
    limit = 100
    alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit:, last_triggered_at:)

    expect(Util).to receive(:send_email).with("user@example.com", "Usage alert is triggered for project project1",
      greeting: "Hello User1,",
      body: ["The usage alert, alert1, you set for project project1 (id: #{project.ubid}) has been triggered.",
        "Current cost: $110.0",
        "Please note that this alert is only for informational purposes and no action is taken automatically."],
      button_title: "See usage",
      button_link: "#{Config.base_url}#{project.path}/billing")
    expect { alert.trigger(limit + 10) }.to change { alert.last_triggered_at }.from(last_triggered_at).to(now)
    expect(project.reload.cutoff_at).to be_nil
  end

  it "trigger for spending cutoff sends email, sets project cutoff_at, and updates last_triggered_at" do
    limit = 100
    alert = described_class.create(project_id: project.id, user_id: user.id, name: "cutoff", limit:, cutoff: true)

    expect(Util).to receive(:send_email).with("user@example.com", "Spending cutoff for project project1",
      greeting: "Hello User1,",
      body: ["The spending cutoff you set for project project1 (id: #{project.ubid}) has been triggered.",
        "Current cost: $110.0",
        "New resource creation will no longer be allowed this month unless you increase or remove the spending cutoff."],
      button_title: "See usage",
      button_link: "#{Config.base_url}#{project.path}/billing")
    expect(project.cutoff_at).to be_nil
    alert.trigger(limit + 10)
    expect(project.reload.cutoff_at).to be_within(60).of(Time.now)
    expect(alert.last_triggered_at).not_to be_nil
  end
end
