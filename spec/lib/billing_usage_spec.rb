# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BillingUsage do
  let(:project) { Project.create(name: "usage") }
  let(:now) { Time.utc(2026, 11, 15) }
  let(:month_start) { Time.utc(2026, 11) }

  def vm_rate
    BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1", false, BILLING_RATE_ACTIVE_AT)
  end

  def runner_rate
    BillingRate.from_resource_properties("GitHubRunnerMinutes", "standard-4", "global", false, BILLING_RATE_ACTIVE_AT)
  end

  def create_vm_record(span)
    BillingRecord.create(
      project_id: project.id,
      resource_id: Vm.generate_uuid,
      resource_name: "vm",
      span:,
      billing_rate_id: vm_rate["id"],
      amount: 2,
    )
  end

  def create_runner_record(day, amount: 100)
    start = Time.utc(2026, 11, day)
    BillingRecord.create(
      project_id: project.id,
      resource_id: GithubRunner.generate_uuid,
      resource_name: "runner",
      span: Sequel::Postgres::PGRange.new(start, start + 86400),
      billing_rate_id: runner_rate["id"],
      amount:,
    )
  end

  it "maps every billed resource type to a service" do
    resource_types = BillingRate.rates.map { it["resource_type"] }.uniq
    expect(resource_types - described_class::SERVICE_BY_RESOURCE_TYPE.keys).to be_empty
  end

  describe ".amount_billed_scale" do
    it "does not scale before seven full days of the month" do
      expect(described_class.amount_billed_scale(Time.utc(2026, 11, 7, 23, 59, 59))).to be_nil
    end

    it "scales once seven full days have elapsed" do
      expect(described_class.amount_billed_scale(Time.utc(2026, 11, 8))).to be_within(1e-12).of(30.0 / 7)
    end
  end

  describe "#series" do
    it "returns nil without usage" do
      expect(described_class.new(project, now:).series).to be_nil
    end

    it "does not extrapolate amount-billed usage before seven full days" do
      early_now = Time.utc(2026, 11, 5)
      create_runner_record(1)
      series = described_class.new(project, now: early_now).series

      expect(series[:actual].last[1]).to eq((100 * runner_rate["unit_price"]).round(3))
      expect(series[:projected].last[1]).to eq(series[:actual].last[1])
    end

    it "matches the current and projected invoice subtotals" do
      create_vm_record(Sequel::Postgres::PGRange.new(month_start, nil))
      create_runner_record(1)

      series = described_class.new(project, now:).series

      expect(series[:actual].last[1]).to eq(project.current_invoice(end_time: now).subtotal)
      expect(series[:projected].last[1]).to eq(project.projected_invoice(now:).subtotal)
      expect(series[:projected].first[1]).to eq(series[:actual].last[1])
      expect(series[:projected].last[0]).to eq(Time.utc(2026, 12).to_i * 1000)
    end

    it "flattens always-on resources after the 672 hour cap" do
      late_now = Time.utc(2026, 11, 30, 12)
      create_vm_record(Sequel::Postgres::PGRange.new(month_start, nil))
      series = described_class.new(project, now: late_now).series
      capped_cost = (2 * 672 * 60 * vm_rate["unit_price"]).round(3)

      capped_points = series[:actual].select { |timestamp, _| timestamp >= Time.utc(2026, 11, 29).to_i * 1000 }
      expect(capped_points.map(&:last).uniq).to eq([capped_cost])
      expect(series[:projected].last[1]).to eq(capped_cost)
      expect(project.projected_invoice(now: late_now).subtotal).to eq(capped_cost)
    end

    it "does not grow after a record ends" do
      create_vm_record(Sequel::Postgres::PGRange.new(month_start, Time.utc(2026, 11, 6)))
      series = described_class.new(project, now:).series
      expected_cost = (2 * 5 * 24 * 60 * vm_rate["unit_price"]).round(3)

      points_after_end = series[:actual].select { |timestamp, _| timestamp >= Time.utc(2026, 11, 6).to_i * 1000 }
      expect(points_after_end.map(&:last).uniq).to eq([expected_cost])
      expect(series[:projected].last[1]).to eq(expected_cost)
    end

    it "returns every daily point, clipped to the month, before amount-billed usage is projected" do
      pinned_now = Time.utc(2026, 11, 3, 12)
      create_vm_record(Sequel::Postgres::PGRange.new(Time.utc(2026, 10, 25), nil))
      create_runner_record(2)
      series = described_class.new(project, now: pinned_now).series

      ms = ->(time) { time.to_i * 1000 }
      runner = (100 * runner_rate["unit_price"]).round(3)
      total = ->(vm_minutes, runner_cost) { ((2 * vm_minutes * vm_rate["unit_price"]).round(3) + runner_cost).round(3) }
      capped = 672 * 60

      expect(series.slice(:month_start_ms, :month_end_ms, :last_day)).to eq(month_start_ms: ms.call(month_start), month_end_ms: ms.call(Time.utc(2026, 12)), last_day: 30)
      expect(series[:actual]).to eq([
        [ms.call(Time.utc(2026, 11, 1)), 0.0],
        [ms.call(Time.utc(2026, 11, 2)), total.call(1440, 0)],
        [ms.call(Time.utc(2026, 11, 3)), total.call(2880, runner)],
        [ms.call(pinned_now), total.call(3600, runner)],
      ])
      expect(series[:projected]).to eq([
        [ms.call(pinned_now), total.call(3600, runner)],
        *(4..30).map { [ms.call(Time.utc(2026, 11, it)), total.call([(it - 1) * 1440, capped].min, runner)] },
        [ms.call(Time.utc(2026, 12)), total.call(capped, runner)],
      ])
    end

    it "scales amount-billed usage at each projected point by the time elapsed" do
      scaled_now = Time.utc(2026, 11, 10)
      create_runner_record(2, amount: 900)
      projected = described_class.new(project, now: scaled_now).series[:projected].to_h
      scaled = ->(day) { (900 * (Time.utc(2026, 11, day) - month_start).fdiv(scaled_now - month_start) * runner_rate["unit_price"]).round(3) }

      expect(projected[scaled_now.to_i * 1000]).to eq((900 * runner_rate["unit_price"]).round(3))
      expect(projected[Time.utc(2026, 11, 20).to_i * 1000]).to eq(scaled.call(20))
      expect(projected[Time.utc(2026, 12).to_i * 1000]).to eq((900 * (Time.utc(2026, 12) - month_start).fdiv(scaled_now - month_start) * runner_rate["unit_price"]).round(3))
    end

    it "splits usage by service so the services add up to the total" do
      create_vm_record(Sequel::Postgres::PGRange.new(month_start, nil))
      create_runner_record(3)
      series = described_class.new(project, now:).series

      expect(series[:services]).to eq(["Compute", "GitHub Runners"])
      [:actual, :projected].each do |kind|
        series[kind].each_with_index do |(timestamp, total), index|
          service_values = series[:services].map { series[:service_points][it][kind][index] }
          expect(service_values.map(&:first).uniq).to eq([timestamp])
          expect(service_values.sum(&:last).round(3)).to eq(total)
        end
      end

      runner_points = series[:service_points]["GitHub Runners"]
      expect(runner_points[:actual].first).to eq([month_start.to_i * 1000, 0.0])
      expect(runner_points[:projected].last[1]).to eq((100 * 30.0 / 14 * runner_rate["unit_price"]).round(3))
      expect(series[:service_points]["Compute"][:projected].last[1]).to eq((2 * 672 * 60 * vm_rate["unit_price"]).round(3))
    end

    it "accumulates daily amount-billed records and projects them" do
      3.times { |day| create_runner_record(day + 1) }
      series = described_class.new(project, now:).series

      to_date_unit = (100 * runner_rate["unit_price"]).round(3)
      projected_unit = (100 * 30.0 / 14 * runner_rate["unit_price"]).round(3)
      expect(series[:actual].last[1]).to eq((to_date_unit * 3).round(3))
      expect(series[:actual].map(&:last)).to include(to_date_unit, (to_date_unit * 2).round(3), (to_date_unit * 3).round(3))
      expect(series[:projected].last[1]).to eq((projected_unit * 3).round(3))
    end
  end
end
