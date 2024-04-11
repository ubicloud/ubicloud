# frozen_string_literal: true

class Prog::CheckUsageAlerts < Prog::Base
  label def wait
    begin_time = Date.new(Time.now.year, Time.now.month, 1).to_time

    alerts = UsageAlert.where { last_triggered_at < begin_time }
    alerts.each do |alert|
      cost = alert.project.current_invoice.content["cost"]
      alert.trigger if cost > alert.limit
    end

    nap 5 * 60
  end
end
