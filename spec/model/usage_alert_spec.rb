# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UsageAlert do
  it "trigger sends email and updates last_triggered_at" do
    now = Time.now.round
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    last_triggered_at = now - 42 * 24 * 60 * 60
    limit = 100
    alert = described_class.create(project_id: Project.create(name: "project1").id, user_id: Account.create(email: "user@example.com").id, name: "alert1", limit:, last_triggered_at:)

    expect(Util).to receive(:send_email)
    expect { alert.trigger(limit + 10) }.to change { alert.last_triggered_at }.from(last_triggered_at).to(now)
  end
end
