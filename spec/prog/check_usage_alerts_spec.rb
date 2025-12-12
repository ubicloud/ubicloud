# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckUsageAlerts do
  subject(:prog) {
    described_class.new(Strand.create_with_id("645cc9ff-7954-1f3a-fa82-ec6b3ffffff5", prog: "CheckUsageAlerts", label: "wait"))
  }

  describe "#wait" do
    it "triggers alerts if usage is exceeded given threshold" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project1 = Project.create(name: "project1")
      project2 = Project.create(name: "project2")
      limit = 100
      alert1 = UsageAlert.create(project_id: project1.id, name: "alert1", user_id:, limit:, last_triggered_at:)
      alert2 = UsageAlert.create(project_id: project2.id, name: "alert2", user_id:, limit:, last_triggered_at:)

      [[project1, 1_000_000], [project2, 100]].each do |project, amount|
        BillingRecord.create(
          project_id: project.id,
          resource_id: "d5c1c540-407e-8374-a5f3-337204777db4",
          resource_name: "test",
          span: Sequel::Postgres::PGRange.new(Time.now, Time.now + 1),
          billing_rate_id: BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-hel1")["id"],
          amount:
        )
      end

      expect { prog.wait }.to nap(5 * 60)
      expect(alert1.reload.last_triggered_at).not_to eq(last_triggered_at)
      expect(alert2.reload.last_triggered_at).to eq(last_triggered_at)
    end
  end
end
