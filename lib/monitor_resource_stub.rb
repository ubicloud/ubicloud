# frozen_string_literal: true

# Only used by the monitor smoke test
# :nocov:
class MonitorResourceStub
  OBJECTS = []

  class Session
    def loop(sleep_for)
      Kernel.loop do
        sleep(sleep_for)
        break unless yield
      end
    end

    def shutdown!
      nil
    end

    def close
      nil
    end
  end

  def self.add(...)
    OBJECTS << new(...)
  end

  def self.where_each(_range, &)
    OBJECTS.each(&)
  end

  def self.count
    OBJECTS.size
  end

  attr_reader :id, :ubid

  def initialize(ubid, need_event_loop: false, pulse: "up", metrics_count: 1)
    @id = ubid.to_uuid
    @ubid = ubid.to_s
    @need_event_loop = need_event_loop
    @pulse_count = 0
    @pulse = pulse
    @metrics_counts = metrics_count
  end

  def needs_event_loop_for_pulse_check?
    @need_event_loop
  end

  def check_pulse(session:, previous_pulse:)
    @pulse_count += 1
    sleep(0.1 + rand)
    {reading: @pulse, reading_rpt: @pulse_count}
  end

  def export_metrics(session:, tsdb_client:)
    sleep(0.1 + rand)
    @metrics_counts
  end

  def reload
    self
  end

  def init_health_monitor_session
    {ssh_session: Session.new}
  end
  alias_method :init_metrics_export_session, :init_health_monitor_session

  def metrics_config
    {}
  end
end
# :nocov:
