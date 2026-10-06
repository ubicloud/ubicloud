# frozen_string_literal: true

class Prog::CheckUsageAlerts < Prog::Base
  frame_accessor :last_usage_alert_id

  label def wait
    hop_process_alerts if last_usage_alert_id
    self.last_usage_alert_id = "00000000-0000-0000-0000-000000000000"
    nap 5 * 60
  end

  label def process_alerts
    now = Time.now
    begin_time = Time.utc(now.year, now.month)

    alerts = UsageAlert
      .order(:id)
      .limit(100)
      .eager(:project)
      .where { last_triggered_at < begin_time }
      .where { it.id > last_usage_alert_id }
      .all

    alerts_by_project = alerts.group_by(&:project)
    project_ids = alerts_by_project.keys.map!(&:id)
    discounts_and_credits_hashes = InvoiceGenerator.discounts_and_credits_hashes(begin_time, Time.now.utc, project_ids)

    alerts_by_project.each do |project, project_alerts|
      content = project.current_invoice(since: begin_time, discounts_and_credits_hashes:).content
      cost = content["subtotal"] - content["discount"]
      project_alerts.each do |alert|
        alert.trigger(cost) if cost > alert.limit
      end
    end

    if alerts.length == 100
      self.last_usage_alert_id = alerts.last.id
      nap 0
    end

    self.last_usage_alert_id = nil
    hop_wait
  end
end
