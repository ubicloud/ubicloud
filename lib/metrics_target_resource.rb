# frozen_string_literal: true

class MetricsTargetResource
  attr_reader :deleted, :resource
  attr_accessor :monitor_job_started_at, :monitor_job_finished_at

  def initialize(resource)
    @resource = resource
    @session = nil
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
    return if @deleted

    @export_started_at = Time.now
    begin
      count = @resource.export_metrics(session: @session, tsdb_client: @tsdb_client)
      Clog.emit("Metrics export has finished.") { {metrics_export_success: {ubid: @resource.ubid, count: count}} }
      @last_export_success = true
    rescue => ex
      @last_export_success = false
      close_resource_session
      Clog.emit("Metrics export has failed.") { {metrics_export_failure: {ubid: @resource.ubid, exception: Util.exception_to_hash(ex)}} }
      # TODO: Consider raising the exception here, and let the caller handle it.
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
end
