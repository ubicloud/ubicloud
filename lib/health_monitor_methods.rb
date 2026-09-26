# frozen_string_literal: true

module HealthMonitorMethods
  def aggregate_readings(previous_pulse:, reading:, data: {})
    {
      reading:,
      reading_rpt: (previous_pulse[:reading] == reading) ? previous_pulse[:reading_rpt] + 1 : 1,
      reading_chg: (previous_pulse[:reading] == reading) ? previous_pulse[:reading_chg] : Time.now,
    }.merge(data)
  end

  def needs_event_loop_for_pulse_check?
    false
  end

  def page_on_sshable_failure?
    true
  end

  def open_session_failure_page_threshold
    MonitorableResource::OPEN_SESSION_FAILURE_PAGE_THRESHOLD
  end
end
