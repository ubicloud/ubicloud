# frozen_string_literal: true

class Prog::CheckUsageAlerts < Prog::Base
  frame_accessor :current_range_index

  RANGES = Array.new(16) do
    start = it
    start_ubid = "#{"%x" % start}0000000-0000-0000-0000-000000000000".freeze
    if it == 15
      start_ubid..("ffffffff-ffff-ffff-ffff-ffffffffffff")
    else
      finish = start + 1
      start_ubid...("#{"%x" % finish}0000000-0000-0000-0000-000000000000".freeze)
    end
  end.freeze

  label def wait
    begin_time = Date.new(Time.now.year, Time.now.month, 1).to_time
    self.current_range_index ||= 0

    alerts = UsageAlert
      .where(id: RANGES[current_range_index])
      .eager(:project)
      .where { last_triggered_at < begin_time }
      .all

    alerts.group_by(&:project).each do |project, project_alerts|
      content = project.current_invoice(since: begin_time).content
      cost = content["subtotal"] - content["discount"]
      project_alerts.each do |alert|
        alert.trigger(cost) if cost > alert.limit
      end
    end

    self.current_range_index = (current_range_index == 15) ? 0 : (current_range_index + 1)
    nap 18
  end
end
