# frozen_string_literal: true

class MetricsTargetResource
  EXPORT_TIMEOUT = 100

  attr_reader :deleted

  def initialize(resource)
    @resource = resource
    @session = nil
    @mutex = Mutex.new
    @last_export_success = false
    @export_started_at = Time.now
    @deleted = false

    vmr = VictoriaMetricsResource.first(project_id: resource.metrics_config[:project_id])
    vms = vmr&.servers&.first
    @tsdb_client = vms&.client || (VictoriaMetrics::Client.new(endpoint: "http://localhost:8428") if Config.development?)
  end

  def open_resource_session
    return if @session && @last_export_success

    @session = @resource.reload.init_metrics_export_session
  rescue => ex
    if ex.is_a?(Sequel::NoExistingObject)
      Clog.emit("Resource is deleted.") { {resource_deleted: {ubid: @resource.ubid}} }
      @session = nil
      @deleted = true
    end
  end

  def export_metrics
    @export_started_at = Time.now
    begin
      count = @resource.export_metrics(session: @session, tsdb_client: @tsdb_client)
      Clog.emit("Metrics export has finished.") { {metrics_export_success: {ubid: @resource.ubid, count: count}} }
      @last_export_success = true
    rescue => ex
      @last_export_success = false
      close_resource_session
      Clog.emit("Metrics export has failed.") { {metrics_export_failure: {ubid: @resource.ubid, exception: Util.exception_to_hash(ex)}} }
    end
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

  def force_stop_if_stuck
    if @mutex.locked?
      Clog.emit("Resource is locked.") { {resource_locked: {ubid: @resource.ubid}} }
      if @export_started_at + EXPORT_TIMEOUT < Time.now
        Clog.emit("Metrics export has stuck.") { {metrics_export_stuck: {ubid: @resource.ubid}} }
      end
    end
  end

  def lock_no_wait
    return unless @mutex.try_lock

    begin
      yield
    ensure
      @mutex.unlock
    end
  end
end
