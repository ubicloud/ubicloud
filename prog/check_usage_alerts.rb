# frozen_string_literal: true

class Prog::CheckUsageAlerts < Prog::Base
  label def wait
    begin_time = Date.new(Time.now.year, Time.now.month, 1).to_time

    alerts = UsageAlert.eager(:project).where { last_triggered_at < begin_time }.all
    alerts.group_by(&:project).each do |project, project_alerts|
      cost = project.current_invoice.content["cost"]
      project_alerts.each do |alert|
        alert.trigger if cost > alert.limit
      end
    end

    nap 5 * 60
  end
end
