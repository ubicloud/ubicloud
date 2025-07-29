# frozen_string_literal: true

class MonitorableResource
  attr_reader :deleted, :run_event_loop, :resource
  attr_accessor :monitor_job_started_at, :monitor_job_finished_at

  def initialize(resource)
    @resource = resource
    @session = nil
    @pulse = {}
    @pulse_check_started_at = Time.now
    @pulse_thread = nil
    @run_event_loop = false
    @deleted = false
  end

  def open_resource_session
    return if @session && @pulse[:reading] == "up"

    @session = @resource.reload.init_health_monitor_session
  rescue => ex
    if ex.is_a?(Sequel::NoExistingObject)
      Clog.emit("Resource is deleted.") { {resource_deleted: {ubid: @resource.ubid}} }
      @session = nil
      @deleted = true
    end
  end

  def process_event_loop
    return if @session.nil? || !@resource.needs_event_loop_for_pulse_check?

    @pulse_thread = Thread.new do
      sleep 0.01 until @run_event_loop
      @session[:ssh_session].loop(0.01) { @run_event_loop }
    rescue => ex
      Clog.emit("SSH event loop has failed.") { {event_loop_failure: {ubid: @resource.ubid, exception: Util.exception_to_hash(ex)}} }
      close_resource_session
    end
  end

  def check_pulse
    @run_event_loop = true if @resource.needs_event_loop_for_pulse_check?

    @pulse_check_started_at = Time.now
    begin
      @pulse = @resource.check_pulse(session: @session, previous_pulse: @pulse)
      Clog.emit("Got new pulse.") { {got_pulse: {ubid: @resource.ubid, pulse: @pulse}} } if @pulse[:reading_rpt] < 6 || @pulse[:reading_rpt] % 5 == 1 || @pulse[:reading] != "up"
    rescue => ex
      Clog.emit("Pulse checking has failed.") { {pulse_check_failure: {ubid: @resource.ubid, exception: Util.exception_to_hash(ex)}} }
    end

    @run_event_loop = false if @resource.needs_event_loop_for_pulse_check?
    @pulse_thread&.join
  end

  def close_resource_session
    return if @session.nil?

    @session[:ssh_session].shutdown!
    begin
      @session[:ssh_session].close
    rescue
    end
    @session = nil
  end
end
