# frozen_string_literal: true

module MetricsTargetMethods
  MAX_SCRAPE_FETCH_COUNT = 4
  FILENAME_FORMAT = "%Y-%m-%dT%H-%M-%S-%N"

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

      # Directory to store the collected metrics
      metrics_dir: "/home/ubi/metrics",

      # Service Project ID to use for the metrics storage
      project_id: Config.victoria_metrics_service_project_id
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

  def scrape_endpoints(session)
    scrape_files = session[:ssh_session].exec!("ls :metrics_dir/done | sort | head -n :fetch_count", metrics_dir:, fetch_count: MAX_SCRAPE_FETCH_COUNT).split("\n")

    scrape_files.filter_map do |file|
      time_str = file.split(".").first
      time = Time.strptime(time_str, FILENAME_FORMAT)
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
