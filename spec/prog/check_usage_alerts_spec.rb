# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckUsageAlerts do
  subject(:prog) {
    described_class.new(Strand.create_with_id("645cc9ff-7954-1f3a-fa82-ec6b3ffffff5", prog: "CheckUsageAlerts", label: "wait"))
  }

  def create_billing_record(project, amount)
    BillingRecord.create(
      project_id: project.id,
      resource_id: "d5c1c540-407e-8374-a5f3-337204777db4",
      resource_name: "test",
      span: Sequel::Postgres::PGRange.new(Time.now, Time.now + 1),
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-hel1")["id"],
      amount:,
    )
  end

  def create_alert(id, project, user_id, limit:, last_triggered_at:)
    UsageAlert.create_with_id(id, project_id: project.id, name: "alert-#{id}", user_id:, limit:, last_triggered_at:)
  end

  def alert_id(i)
    format("00000000-0000-8000-8000-%012x", i)
  end

  describe "#wait" do
    it "starts processing from the beginning and naps if not processing alerts" do
      expect(prog.last_usage_alert_id).to be_nil
      expect { prog.wait }.to nap(5 * 60)
      expect(prog.last_usage_alert_id).to eq "00000000-0000-0000-0000-000000000000"
    end

    it "hops to process_alerts after napping" do
      prog.last_usage_alert_id = "00000000-0000-0000-0000-000000000000"
      expect { prog.wait }.to hop("process_alerts")
    end
  end

  describe "#process_alerts" do
    let(:last_triggered_at) { Time.now.round - 42 * 24 * 60 * 60 }
    let(:user_id) { Account.create(email: "user@example.com").id }
    let(:project) { Project.create(name: "project1") }

    before do
      prog.last_usage_alert_id = "00000000-0000-0000-0000-000000000000"
    end

    it "processes alerts in batches of 100, napping between batches" do
      create_billing_record(project, 1_000_000)
      100.times { create_alert(alert_id(it + 1), project, user_id, limit: 1_000_000_000, last_triggered_at:) }
      alert = create_alert(alert_id(101), project, user_id, limit: 100, last_triggered_at:)

      expect { prog.process_alerts }.to nap(0)
      expect(prog.last_usage_alert_id).to eq alert_id(100)
      expect(alert.reload.last_triggered_at).to be_within(5).of(last_triggered_at)

      expect { prog.process_alerts }.to hop("wait")
      expect(prog.last_usage_alert_id).to be_nil
      expect(alert.reload.last_triggered_at).to be_within(5).of(Time.now)
    end

    it "only processes alerts after the last processed alert id" do
      create_billing_record(project, 1_000_000)
      before_alert = create_alert(alert_id(1), project, user_id, limit: 100, last_triggered_at:)
      after_alert = create_alert(alert_id(3), project, user_id, limit: 100, last_triggered_at:)
      prog.last_usage_alert_id = alert_id(2)

      expect { prog.process_alerts }.to hop("wait")
      expect(before_alert.reload.last_triggered_at).to be_within(5).of(last_triggered_at)
      expect(after_alert.reload.last_triggered_at).to be_within(5).of(Time.now)
    end

    it "skips alerts already triggered this month" do
      create_billing_record(project, 1_000_000)
      triggered_at = Time.utc(Time.now.year, Time.now.month)
      alert = create_alert(alert_id(1), project, user_id, limit: 100, last_triggered_at: triggered_at)

      expect { prog.process_alerts }.to hop("wait")
      expect(alert.reload.last_triggered_at).to eq triggered_at
    end

    it "triggers alerts if usage is exceeded given threshold" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project1 = Project.create(name: "project1")
      project2 = Project.create(name: "project2")
      limit = 100
      alert1 = UsageAlert.create(project_id: project1.id, name: "alert1", user_id:, limit:, last_triggered_at:)
      alert2 = UsageAlert.create(project_id: project2.id, name: "alert2", user_id:, limit:, last_triggered_at:)

      [[project1, 1_000_000], [project2, 100]].each do |project, amount|
        create_billing_record(project, amount)
      end

      expect { prog.process_alerts }.to hop("wait")
      expect(alert1.reload.last_triggered_at).not_to eq(last_triggered_at)
      expect(alert2.reload.last_triggered_at).to eq(last_triggered_at)
    end

    it "does not trigger alerts if discounts bring usage below the threshold" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")
      alert = UsageAlert.create(project_id: project.id, name: "alert", user_id:, limit: 100, last_triggered_at:)
      ResourceDiscount.create(project_id: project.id, discount_percent: 100, active_from: Time.utc(Time.now.year, Time.now.month), name: "Full discount")
      create_billing_record(project, 1000000)

      expect { prog.process_alerts }.to hop("wait")
      expect(alert.reload.last_triggered_at).to eq(last_triggered_at)
    end

    it "triggers alerts if usage exceeds the threshold even if credits cover the usage" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")
      create_billing_record(project, 1000000)

      usage = project.current_invoice.content["cost"]
      alert = UsageAlert.create(project_id: project.id, name: "alert", user_id:, limit: usage * 0.8, last_triggered_at:)
      ResourceCredit.create(project_id: project.id, amount: usage * 1.2, active_from: Time.utc(Time.now.year, Time.now.month), name: "Credit")
      expect(project.current_invoice.content["cost"]).to eq 0

      expect { prog.process_alerts }.to hop("wait")
      expect(alert.reload.last_triggered_at).not_to eq(last_triggered_at)
    end

    it "only considers current month usage even if previous month invoice is not yet generated" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")
      billing_rate = BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-hel1")

      begin_of_current_month = Time.new(Time.now.year, Time.now.month, 1)
      begin_of_previous_month = (begin_of_current_month.to_date << 1).to_time

      # Simulate an old invoice ending at the beginning of the previous month,
      # meaning the previous month's invoice has NOT been generated yet.
      # Without the fix, current_invoice would use this end_time as begin_time,
      # including the previous month's billing records in the cost calculation.
      Invoice.create(
        project_id: project.id,
        invoice_number: "test-invoice-01",
        content: {cost: 0},
        begin_time: (begin_of_previous_month.to_date << 1).to_time,
        end_time: begin_of_previous_month,
      )

      # Previous month: high usage that would push total over the limit
      BillingRecord.create(
        project_id: project.id,
        resource_id: "d5c1c540-407e-8374-a5f3-337204777db4",
        resource_name: "test-prev",
        span: Sequel::Postgres::PGRange.new(begin_of_previous_month, begin_of_current_month),
        billing_rate_id: billing_rate["id"],
        amount: 1_000_000,
      )

      # Current month: low usage that is below the limit
      BillingRecord.create(
        project_id: project.id,
        resource_id: "d5c1c540-407e-8374-a5f3-337204777db4",
        resource_name: "test-curr",
        span: Sequel::Postgres::PGRange.new(begin_of_current_month, Time.now + 1),
        billing_rate_id: billing_rate["id"],
        amount: 100,
      )

      # Set limit between current month cost and combined (prev + current) cost
      current_month_cost = project.current_invoice(since: begin_of_current_month).content["cost"]
      combined_cost = project.current_invoice(since: begin_of_previous_month).content["cost"]
      limit = (current_month_cost + combined_cost) / 2

      alert = UsageAlert.create(project_id: project.id, name: "alert", user_id:, limit:, last_triggered_at:)

      expect { prog.process_alerts }.to hop("wait")
      expect(alert.reload.last_triggered_at).to eq(last_triggered_at)
    end
  end
end
