# frozen_string_literal: true

class MonitorableResource
  attr_reader :deleted, :resource, :attached_resources
  attr_accessor :monitor_job_started_at, :monitor_job_finished_at
  attr_writer :session

  def initialize(resource)
    @resource = resource
    @session = nil
    @pulse = {}
    @pulse_check_started_at = Time.now
    @pulse_thread = nil
    @deleted = false
    if resource.is_a?(VmHost)
      @attached_resources = {}
      @attached_resources_mutex = Mutex.new
    end
  end

  def attached_resources_sync(&)
    @attached_resources_mutex.synchronize(&)
  end

  def open_resource_session
    return if @session && @pulse[:reading] == "up"

    @session = @resource.reload.init_health_monitor_session
  rescue Sequel::NoExistingObject
    Clog.emit("Resource is deleted.", {resource_deleted: {ubid: @resource.ubid}})
    @session = nil
    @deleted = true
  end

  def check_pulse
    return unless @session

    if @resource.needs_event_loop_for_pulse_check?
      run_event_loop = true
      event_loop_failed = false
      pulse_thread = Thread.new do
        @session[:ssh_session].loop(0.01) { run_event_loop }
      rescue => ex
        event_loop_failed = true
        Clog.emit("SSH event loop has failed.", {event_loop_failure: Util.exception_to_hash(ex, into: {ubid: @resource.ubid})})
        @session[:ssh_session].shutdown!
        begin
          @session[:ssh_session].close
        rescue
        end
      end
    end

    stale_retry = false
    @pulse_check_started_at = Time.now
    begin
      @pulse = @resource.check_pulse(session: @session, previous_pulse: @pulse)
      @session[:last_pulse] = Time.now
      Clog.emit("Got new pulse.", {got_pulse: {ubid: @resource.ubid, pulse: @pulse}}) if (rpt = @pulse[:reading_rpt]) && (rpt < 6 || rpt % 5 == 1) || @pulse[:reading] != "up"
    rescue => ex
      if !stale_retry &&
          (
            # Seen when sending on a broken connection.
            ex.is_a?(IOError) && ex.message == "closed stream" ||
            # Seen when receiving on a broken connection.
            ex.is_a?(Errno::ECONNRESET) && ex.message.start_with?("Connection reset by peer - recvfrom(2)")
          ) &&
          (@session[:last_pulse].nil? || @session[:last_pulse] < (Time.now - 8))
        stale_retry = true
        begin
          @session[:ssh_session].shutdown!
        rescue
        end
        @session.merge!(@resource.init_health_monitor_session)
        retry
      end

      begin
        @resource.reload
      rescue Sequel::NoExistingObject
        @deleted = true
        Clog.emit("Resource is deleted.", {resource_deleted: {ubid: resource.ubid}})
      else
        Clog.emit("Pulse checking has failed.", {pulse_check_failure: Util.exception_to_hash(ex, into: {ubid: @resource.ubid})})
      end
      # TODO: Consider raising the exception here, and let the caller handle it.
    end

    run_event_loop = false
    pulse_thread&.join
    @session = nil if event_loop_failed

    return unless @session && @session[:ssh_session] && @attached_resources

    delete_attached_resource_ids = []

    attached_resources_sync { @attached_resources.values }.each do |resource|
      resource.session = @session
      resource.check_pulse
      delete_attached_resource_ids << resource.resource.id if resource.deleted
      break unless @session[:ssh_session]
    end

    attached_resources_sync do
      delete_attached_resource_ids.each do
        @attached_resources.delete(it)
      end
    end

    nil
  end
end
