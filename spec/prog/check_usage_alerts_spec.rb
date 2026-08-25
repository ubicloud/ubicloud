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
          amount:,
        )
      end

      expect { prog.wait }.to nap(5 * 60)
      expect(alert1.reload.last_triggered_at).not_to eq(last_triggered_at)
      expect(alert2.reload.last_triggered_at).to eq(last_triggered_at)
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

      expect { prog.wait }.to nap(5 * 60)
      expect(alert.reload.last_triggered_at).to eq(last_triggered_at)
    end

    it "scopes cost to the alert's resource_type instead of total project cost" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")

      runner_rate = BillingRate.from_resource_properties("GitHubRunnerMinutes", "standard-2", "global")
      cache_rate = BillingRate.from_resource_properties("GitHubCacheStorage", "standard", "global")
      runner_cost = 5.0
      cache_cost = 500.0

      BillingRecord.create(
        project_id: project.id,
        resource_id: "d5c1c540-407e-8374-a5f3-337204777db4",
        resource_name: "runner",
        span: Sequel::Postgres::PGRange.new(Time.now, Time.now + 1),
        billing_rate_id: runner_rate["id"],
        amount: (runner_cost / runner_rate["unit_price"]).ceil,
      )
      BillingRecord.create(
        project_id: project.id,
        resource_id: "e5c1c540-407e-8374-a5f3-337204777db4",
        resource_name: "cache",
        span: Sequel::Postgres::PGRange.new(Time.now, Time.now + 60),
        billing_rate_id: cache_rate["id"],
        amount: (cache_cost / cache_rate["unit_price"]).ceil,
      )

      limit = 50 # between the runner-only cost and the runner+cache total
      runner_alert = UsageAlert.create(project_id: project.id, name: "runner-alert", user_id:, limit:, last_triggered_at:, resource_type: "GithubRunner", hard_limit: true)
      whole_project_alert = UsageAlert.create(project_id: project.id, name: "whole-alert", user_id:, limit:, last_triggered_at:)

      expect { prog.wait }.to nap(5 * 60)
      expect(runner_alert.reload.last_triggered_at).to eq(last_triggered_at)
      expect(whole_project_alert.reload.last_triggered_at).not_to eq(last_triggered_at)
    end

    it "does not re-trigger a hard limit alert again within the same month" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")
      alert = UsageAlert.create(project_id: project.id, name: "runner-alert", user_id:, limit: 1, last_triggered_at:, resource_type: "GithubRunner", hard_limit: true)

      BillingRecord.create(
        project_id: project.id,
        resource_id: "d5c1c540-407e-8374-a5f3-337204777db4",
        resource_name: "runner",
        span: Sequel::Postgres::PGRange.new(Time.now, Time.now + 1),
        billing_rate_id: BillingRate.from_resource_properties("GitHubRunnerMinutes", "standard-2", "global")["id"],
        amount: 100_000,
      )

      expect { prog.wait }.to nap(5 * 60)
      triggered_at = alert.reload.last_triggered_at
      expect(triggered_at).not_to eq(last_triggered_at)
      expect(UsageAlert.where(id: alert.id).hard_limit_active.any?).to be true

      expect { prog.wait }.to nap(5 * 60)
      expect(alert.reload.last_triggered_at).to eq(triggered_at)
    end
  end
end
