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

  def create_alert(id, project, limit: 100, last_triggered_at: Time.now.round - 42 * 24 * 60 * 60)
    UsageAlert.create_with_id(id, project_id: project.id, name: "alert", user_id: Account.create(email: "user-#{id}@example.com").id, limit:, last_triggered_at:)
  end

  def range_index(alert)
    alert.id[0].to_i(16)
  end

  describe "RANGES" do
    it "partitions the uuid space into 16 ranges by first hex digit" do
      ranges = described_class::RANGES
      expect(ranges.size).to eq 16
      expect(ranges.first).to eq("00000000-0000-0000-0000-000000000000"..."10000000-0000-0000-0000-000000000000")
      expect(ranges[9]).to eq("90000000-0000-0000-0000-000000000000"..."a0000000-0000-0000-0000-000000000000")
      expect(ranges.last).to eq("f0000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
      ranges.each_cons(2) { |a, b| expect(a.end).to eq b.begin }
    end
  end

  describe "#wait" do
    let(:project) { Project.create(name: "project1") }

    it "starts with the first range, only checks alerts in that range, and advances to the next range" do
      create_billing_record(project, 1_000_000)
      in_range = create_alert("0fffffff-ffff-8fff-bfff-ffffffffffff", project)
      out_of_range = create_alert("10000000-0000-8000-8000-000000000000", project)
      last_triggered_at = in_range.last_triggered_at
      expect(prog.current_range_index).to be_nil

      expect { prog.wait }.to nap(18)
      expect(prog.current_range_index).to eq 1
      expect(in_range.reload.last_triggered_at).to be_within(5).of(Time.now)
      expect(out_of_range.reload.last_triggered_at).to be_within(5).of(last_triggered_at)

      expect { prog.wait }.to nap(18)
      expect(prog.current_range_index).to eq 2
      expect(out_of_range.reload.last_triggered_at).to be_within(5).of(Time.now)
    end

    it "uses the current range index from the frame" do
      create_billing_record(project, 1_000_000)
      in_range = create_alert("a0000000-0000-8000-8000-000000000000", project)
      before_range = create_alert("9fffffff-ffff-8fff-bfff-ffffffffffff", project)
      after_range = create_alert("b0000000-0000-8000-8000-000000000000", project)
      last_triggered_at = in_range.last_triggered_at
      prog.current_range_index = 10

      expect { prog.wait }.to nap(18)
      expect(prog.current_range_index).to eq 11
      expect(in_range.reload.last_triggered_at).to be_within(5).of(Time.now)
      expect(before_range.reload.last_triggered_at).to be_within(5).of(last_triggered_at)
      expect(after_range.reload.last_triggered_at).to be_within(5).of(last_triggered_at)
    end

    it "includes the maximum uuid in the last range" do
      create_billing_record(project, 1_000_000)
      alert = create_alert("ffffffff-ffff-ffff-ffff-ffffffffffff", project)
      prog.current_range_index = 15

      expect { prog.wait }.to nap(18)
      expect(alert.reload.last_triggered_at).to be_within(5).of(Time.now)
    end

    it "wraps around to the first range after the last range" do
      create_billing_record(project, 1_000_000)
      first_range = create_alert("00000000-0000-8000-8000-000000000000", project)
      last_triggered_at = first_range.last_triggered_at
      prog.current_range_index = 15

      expect { prog.wait }.to nap(18)
      expect(prog.current_range_index).to eq 0
      expect(first_range.reload.last_triggered_at).to be_within(5).of(last_triggered_at)

      expect { prog.wait }.to nap(18)
      expect(prog.current_range_index).to eq 1
      expect(first_range.reload.last_triggered_at).to be_within(5).of(Time.now)
    end

    it "triggers alerts if usage is exceeded given threshold" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project1 = Project.create(name: "project1")
      project2 = Project.create(name: "project2")
      limit = 100
      alert1 = UsageAlert.create_with_id("50000000-0000-8000-8000-000000000001", project_id: project1.id, name: "alert1", user_id:, limit:, last_triggered_at:)
      alert2 = UsageAlert.create_with_id("50000000-0000-8000-8000-000000000002", project_id: project2.id, name: "alert2", user_id:, limit:, last_triggered_at:)
      prog.current_range_index = 5

      [[project1, 1_000_000], [project2, 100]].each do |project, amount|
        create_billing_record(project, amount)
      end

      expect { prog.wait }.to nap(18)
      expect(alert1.reload.last_triggered_at).not_to eq(last_triggered_at)
      expect(alert2.reload.last_triggered_at).to eq(last_triggered_at)
    end

    it "does not trigger alerts if discounts bring usage below the threshold" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")
      alert = UsageAlert.create(project_id: project.id, name: "alert", user_id:, limit: 100, last_triggered_at:)
      prog.current_range_index = range_index(alert)
      ResourceDiscount.create(project_id: project.id, discount_percent: 100, active_from: Time.utc(Time.now.year, Time.now.month), name: "Full discount")
      create_billing_record(project, 1000000)

      expect { prog.wait }.to nap(18)
      expect(alert.reload.last_triggered_at).to eq(last_triggered_at)
    end

    it "triggers alerts if usage exceeds the threshold even if credits cover the usage" do
      last_triggered_at = Time.now.round - 42 * 24 * 60 * 60
      user_id = Account.create(email: "user@example.com").id
      project = Project.create(name: "project1")
      create_billing_record(project, 1000000)

      usage = project.current_invoice.content["cost"]
      alert = UsageAlert.create(project_id: project.id, name: "alert", user_id:, limit: usage * 0.8, last_triggered_at:)
      prog.current_range_index = range_index(alert)
      ResourceCredit.create(project_id: project.id, amount: usage * 1.2, active_from: Time.utc(Time.now.year, Time.now.month), name: "Credit")
      expect(project.current_invoice.content["cost"]).to eq 0

      expect { prog.wait }.to nap(18)
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
      prog.current_range_index = range_index(alert)

      expect { prog.wait }.to nap(18)
      expect(alert.reload.last_triggered_at).to eq(last_triggered_at)
    end
  end
end
