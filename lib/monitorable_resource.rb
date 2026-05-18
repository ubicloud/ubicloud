# frozen_string_literal: true

class MonitorableResource
  attr_reader :deleted, :resource, :attached_resources
  attr_accessor :monitor_job_started_at, :monitor_job_finished_at
  attr_writer :session

  # Page after consecutive monitor session opens have failed for this long.
  # Catches sshd outages while a strand is stuck retrying outside of `wait`.
  OPEN_SESSION_FAILURE_PAGE_THRESHOLD = 5 * 60

  def initialize(resource)
    @resource = resource
    @session = nil
    @pulse = {}
    @pulse_check_started_at = Time.now
    @pulse_thread = nil
    @deleted = false
    @open_session_failure_started_at = nil
    @open_session_failure_paged = false
    if resource.is_a?(VmHost)
      @attached_resources = {}
      @attached_resources_mutex = Mutex.new
    end
  end

  def num_attached_resources
    @attached_resources&.size || 0
  end

  def attached_resources_sync(&)
    @attached_resources_mutex.synchronize(&)
  end

  def open_resource_session
    if @session && @pulse[:reading] == "up"
      clear_open_session_failure
      return
    end

    @session = @resource.reload.init_health_monitor_session
  rescue Sequel::NoExistingObject
    Clog.emit("Resource is deleted.", {resource_deleted: {ubid: @resource.ubid}})
    @session = nil
    @deleted = true
    clear_open_session_failure
  rescue *Sshable::SSH_CONNECTION_ERRORS
    record_open_session_failure
    raise
  else
    clear_open_session_failure
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
          nil
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
          nil
        end
        begin
          new_session = @resource.init_health_monitor_session
        rescue *Sshable::SSH_CONNECTION_ERRORS
          # Drop session so next monitor cycle reinits via open_resource_session,
          # which tracks persistent failures.
          @session = nil
          raise
        end
        @session.merge!(new_session)
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
      unless @session[:ssh_session]
        # If checking the pulse for an attached resource drops the SSH session,
        # remove the resource temporarily. It will be added back on the next scan
        # (within 60s).  Also emit a log message so we can track this information.
        # This is done so a problem with a particular attached resource does not
        # cause monitoring to stop for all attached resources following it.
        delete_attached_resource_ids << resource.resource.id
        Clog.emit("monitor VmHost worker SSH connection lost", {monitor_vm_host_ssh_connection_lost: {host: @resource.ubid, resource: resource.resource.ubid}})
        break
      end
      delete_attached_resource_ids << resource.resource.id if resource.deleted
    end

    attached_resources_sync do
      delete_attached_resource_ids.each do
        @attached_resources.delete(it)
      end
    end

    nil
  end

  private

  def record_open_session_failure
    return unless @resource.page_on_sshable_failure?
    @open_session_failure_started_at ||= Time.now
    return if @open_session_failure_paged
    elapsed = Time.now - @open_session_failure_started_at
    return if elapsed < OPEN_SESSION_FAILURE_PAGE_THRESHOLD

    Prog::PageNexus.assemble(
      "#{@resource.ubid} sshable unreachable for #{elapsed.to_i}s",
      ["SshableUnreachable", @resource.id],
      @resource.ubid,
    )
    @open_session_failure_paged = true
  end

  def clear_open_session_failure
    return unless @open_session_failure_started_at
    Page.from_tag_parts("SshableUnreachable", @resource.id)&.incr_resolve if @open_session_failure_paged
    @open_session_failure_started_at = nil
    @open_session_failure_paged = false
  end
end
