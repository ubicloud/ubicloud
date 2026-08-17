# frozen_string_literal: true

class MetricsTargetResource
  attr_reader :deleted, :resource
  attr_accessor :monitor_job_started_at, :monitor_job_finished_at

  def initialize(resource)
    @resource = resource
    @session = nil
    @last_export_success = false
    @export_started_at = Time.now
    @export_success_streak = 0
    @deleted = false
    @tsdb_client = VictoriaMetricsResource.client_for_project(resource.metrics_config[:project_id])
  end

  def open_resource_session
    return if @session && @last_export_success

    @session = @resource.reload.init_metrics_export_session
  rescue Sequel::NoExistingObject
    Clog.emit("Resource is deleted.", {resource_deleted: {ubid: @resource.ubid}})
    @session = nil
    @deleted = true
  end

  def export_metrics
    return if @deleted

    stale_retry = false
    @export_started_at = Time.now
    begin
      count = @resource.export_metrics(session: @session, tsdb_client: @tsdb_client)
      @session[:last_export] = Time.now
      @export_success_streak += 1
      if @export_success_streak % 20 == 1
        Clog.emit("Metrics export has finished.", {metrics_export_success: {ubid: @resource.ubid, count:, streak: @export_success_streak}})
      end
      @last_export_success = true
    rescue => ex
      if !stale_retry &&
          (
            # Seen when sending on a broken connection.
            ex.is_a?(IOError) && ex.message == "closed stream" ||
            # Seen when receiving on a broken connection.
            ex.is_a?(Errno::ECONNRESET) && ex.message.start_with?("Connection reset by peer - recvfrom(2)")
          ) &&
          (@session[:last_export].nil? || @session[:last_export] < (Time.now - 8))
        stale_retry = true
        begin
          @session[:ssh_session].shutdown!
        rescue
          nil
        end
        begin
          new_session = @resource.init_metrics_export_session
        rescue *Sshable::SSH_CONNECTION_ERRORS
          # Reconnect failed. Fall through to the failure handling below, which
          # drops the session so the next export cycle reinits via
          # open_resource_session.
        else
          @session.merge!(new_session)
          retry
        end
      end

      @export_success_streak = 0
      @last_export_success = false
      close_resource_session
      Clog.emit("Metrics export has failed.", {metrics_export_failure: Util.exception_to_hash(ex, into: {ubid: @resource.ubid})})
      # TODO: Consider raising the exception here, and let the caller handle it.
    end
  end

  def close_resource_session
    return if @session.nil?

    @session[:ssh_session].shutdown!
    begin
      @session[:ssh_session].close
    rescue
      nil
    end
    @session = nil
  end
end
