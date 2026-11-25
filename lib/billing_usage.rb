# frozen_string_literal: true

class BillingUsage
  DAY = 24 * 60 * 60

  SERVICES = {
    "Compute" => %w[VmVCpu VmCores VmStorage Gpu IPAddress],
    "PostgreSQL" => %w[PostgresVCpu PostgresCores PostgresStorage PostgresStandbyVCpu PostgresStandbyCores PostgresStandbyStorage],
    "Kubernetes" => %w[KubernetesControlPlaneVCpu KubernetesWorkerVCpu KubernetesWorkerStorage],
    "GitHub Runners" => %w[GitHubRunnerMinutes GitHubRunnerConcurrency GitHubCacheStorage],
    "AI Inference" => %w[InferenceTokens],
    "Machine Images" => %w[MachineImageStorage],
  }.freeze

  SERVICE_BY_RESOURCE_TYPE = SERVICES.flat_map { |service, types| types.map { [it, service] } }.to_h.freeze

  def self.month_range(now)
    month_start = Time.utc(now.year, now.month)
    month_end_date = Date.new(now.year, now.month, 1) >> 1
    [month_start, Time.utc(month_end_date.year, month_end_date.month)]
  end

  def self.amount_billed_scale(now)
    month_start, month_end = month_range(now)
    elapsed = now - month_start
    return if elapsed < 7 * DAY
    (month_end - month_start).fdiv(elapsed)
  end

  def initialize(project, now: Time.now.utc)
    @now = now
    @month_start, @month_end = self.class.month_range(now)
    @amount_billed_scale = self.class.amount_billed_scale(now)
    @billing_records = BillingRecord
      .where(project_id: project.id)
      .where { |br| Sequel.pg_range(br.span).overlaps(Sequel.pg_range(@month_start...@month_end)) }
      .all
  end

  def series
    actual = actual_times.map { [it, service_subtotals_at(it)] }
    projected = projected_times.map { [it, service_subtotals_at(it)] }
    return if (actual + projected).all? { |_, subtotals| subtotals.values.sum.zero? }

    services = SERVICES.keys & (actual + projected).flat_map { |_, subtotals| subtotals.keys }
    {
      month_start_ms: milliseconds(@month_start),
      month_end_ms: milliseconds(@month_end),
      last_day: Date.new(@now.year, @now.month, -1).day,
      actual: total_points(actual),
      projected: total_points(projected),
      services:,
      service_points: services.to_h { [it, {actual: service_points(actual, it), projected: service_points(projected, it)}] },
    }
  end

  private

  def actual_times
    today = @now.to_date
    times = (1..today.day).map { Time.utc(today.year, today.month, it) }
    times << @now if @now > times.last
    times
  end

  def projected_times
    today = @now.to_date
    last_day = Date.new(today.year, today.month, -1).day
    [@now, *((today.day + 1)..last_day).map { Time.utc(today.year, today.month, it) }, @month_end]
  end

  def milliseconds(time)
    time.to_i * 1000
  end

  def total_points(points)
    points.map { |time, subtotals| [milliseconds(time), subtotals.values.sum.round(3)] }
  end

  def service_points(points, service)
    points.map { |time, subtotals| [milliseconds(time), subtotals.fetch(service, 0.0)] }
  end

  def service_subtotals_at(time)
    records = @billing_records.select { it.span.begin < time }
    durations = InvoiceGenerator.billable_durations(records, @month_start, time)
    amount_scale = amount_scale_at(time)
    subtotals = Hash.new(0)
    records.each do |br|
      rate = br.billing_rate
      amount = br.amount
      amount *= amount_scale if amount_scale && rate["billed_by"] == "amount"
      subtotals[SERVICE_BY_RESOURCE_TYPE.fetch(rate["resource_type"])] += (amount * durations.fetch(br.id) * rate["unit_price"]).round(3)
    end
    subtotals.transform_values { it.to_f.round(3) }
  end

  def amount_scale_at(time)
    return if time <= @now || !@amount_billed_scale
    (time - @month_start).fdiv(@now - @month_start)
  end
end
