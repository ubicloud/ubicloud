# frozen_string_literal: true

# simplecov:disable
environment ENV["RACK_ENV"] || "development"
bind "tcp://0.0.0.0:#{ENV["PORT"] || "3000"}"
threads 15, 15
enable_keep_alives false
silence_fork_callback_warning
silence_single_worker_warning
preload_app!

object_growth_reporter = nil

before_fork do
  Sequel::DATABASES.each(&:disconnect)
  Process.warmup
  PumaWorkerRefresher.run
end
before_worker_boot do |index|
  CONNECTION_CHECKOUT_TELEMETRY&.run_thread
  # A single worker reports: the metrics file store aggregates all workers.
  if index.zero?
    API_METRICS_REPORTER&.run_thread
    if (ENV["DYNO"] || ENV["PS"])&.end_with?("web.1")
      object_growth_reporter = ObjectGrowthReporter.create_if_enabled
      object_growth_reporter&.run_thread
    end
  end
end
before_worker_shutdown do
  CONNECTION_CHECKOUT_TELEMETRY&.shutdown!
  API_METRICS_REPORTER&.shutdown!
  object_growth_reporter&.shutdown!
end
# simplecov:enable
