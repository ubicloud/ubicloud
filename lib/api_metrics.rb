# frozen_string_literal: true

require "prometheus/client"
require "prometheus/client/formats/text"

# Holds the Prometheus registry for API request metrics, recorded by
# ApiMetricsMiddleware and reported to VictoriaMetrics by ApiMetricsReporter.
module ApiMetrics
  DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60].freeze

  def initialize(store_dir: Config.api_metrics_store_dir)
    # Only the web process may own the file store: respirate and monitor also
    # eager-load this class in production and must not wipe or claim it.
    if Config.production? && ENV["PROCESS_TYPE"] == "web"
      require "prometheus/client/data_stores/direct_file_store"
      # Stale files from a previous process would double-count after restart.
      Dir[File.join(store_dir, "*.bin")].each { File.unlink(it) }
      Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir: store_dir)
    end

    @registry = Prometheus::Client::Registry.new
    @request_duration = @registry.histogram(
      :http_request_duration_seconds,
      docstring: "The HTTP request latencies in seconds.",
      labels: [:handler, :method, :code],
      buckets: DURATION_BUCKETS,
    )
  end

  attr_reader :request_duration

  def observe(handler:, method:, code:, duration:)
    @request_duration.observe(duration, labels: {handler:, method:, code:})
  end

  def render
    Prometheus::Client::Formats::Text.marshal(@registry)
  end

  extend self

  initialize
end
