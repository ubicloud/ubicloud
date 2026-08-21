# frozen_string_literal: true

module MetricsTargetMethods
  MAX_SCRAPE_FETCH_COUNT = 4
  FILENAME_FORMAT = "%Y-%m-%dT%H-%M-%S-%N"
  METRICS_BACKLOG_THRESHOLD_SECONDS = 300

  def metrics_config
    {
      # Array of endpoints to collect metrics from
      endpoints: [],

      # Maximum number of files to retain on disk buffer
      max_file_retention: 120,

      # Interval for collecting metrics in seconds or as a time span string
      interval: "15s",

      # Additional label names and values to be added to the collected metrics
      additional_labels: {foo: "bar"},

      # Regexps for scraped lines to drop before buffering/export (optional)
      exclude_metrics: [],

      # Directory to store the collected metrics
      metrics_dir: "/home/ubi/metrics",

      # Service Project ID to use for the metrics storage
      project_id: Config.victoria_metrics_service_project_id,
    }
  end

  def export_metrics(session:, tsdb_client:)
    scrape_results = scrape_endpoints(session)

    if scrape_results.empty?
      return
    end

    if tsdb_client.nil?
      Clog.emit("VictoriaMetrics server is not configured.")
      return
    end

    scrape_results.each do |scrape|
      tsdb_client.import_prometheus(scrape, metrics_config[:additional_labels])
    end

    mark_pending_scrapes_as_done(session, scrape_results[-1].time)
    scrape_results.count
  end

  def observe_metrics_backlog(session)
    tag = metrics_backlog_page_tag
    metrics_done_dir = "#{metrics_dir}/done"
    config_path = "#{metrics_dir}/config.json"
    fields = session[:ssh_session].exec!("echo $(date +%s) $(stat -c %Y :config_path) $(test -d :metrics_done_dir && stat -c %Y :metrics_done_dir || echo 0) $(test -d :metrics_done_dir && ls :metrics_done_dir | wc -l || echo 0)", config_path:, metrics_done_dir:).split
    now, configured_at, collected_at, metrics_backlog = fields.map { Integer(it, 10) }

    if now - [configured_at, collected_at].max > METRICS_BACKLOG_THRESHOLD_SECONDS
      Prog::PageNexus.assemble("#{ubid} is not collecting metrics",
        [tag, id], ubid, severity: "warning")
      return
    end

    metrics_interval = metrics_config[:interval].to_i

    if metrics_backlog * metrics_interval > METRICS_BACKLOG_THRESHOLD_SECONDS
      Prog::PageNexus.assemble("#{ubid} metrics backlog high",
        [tag, id], ubid,
        severity: "warning", extra_data: {metrics_backlog:})
    elsif metrics_backlog * metrics_interval < METRICS_BACKLOG_THRESHOLD_SECONDS * 0.8
      Page.from_tag_parts(tag, id)&.incr_resolve
    end
  end

  def scrape_endpoints(session)
    scrape_files = session[:ssh_session].exec!("ls :metrics_dir/done | sort | head -n :fetch_count", metrics_dir:, fetch_count: MAX_SCRAPE_FETCH_COUNT).split("\n")

    scrape_files.filter_map do |file|
      time_str = file.split(".").first
      time = Time.strptime("#{time_str} UTC", "#{FILENAME_FORMAT} %Z")
      status = {}

      samples = session[:ssh_session].exec!("cat :metrics_dir/done/:file", metrics_dir:, file:, status:)

      VictoriaMetrics::Client::Scrape.new(time:, samples:) if status[:exit_code] == 0
    end
  end

  def mark_pending_scrapes_as_done(session, time)
    marker = time.strftime(FILENAME_FORMAT)
    session[:ssh_session].exec!("ls :metrics_dir/done | sort | awk :awk_script | xargs -I{} rm :metrics_dir/done/{}", metrics_dir:, awk_script: "$0 <= \"#{marker}\"")
  end

  private

  def metrics_dir
    metrics_config[:metrics_dir]
  end
end
