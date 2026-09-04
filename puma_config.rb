# frozen_string_literal: true

# simplecov:disable
environment ENV["RACK_ENV"] || "development"
bind "tcp://0.0.0.0:#{ENV["PORT"] || "3000"}"
threads 15, 15
enable_keep_alives false
silence_fork_callback_warning
silence_single_worker_warning
preload_app!

before_fork do
  Sequel::DATABASES.each(&:disconnect)
end
before_worker_boot do |index|
  CONNECTION_CHECKOUT_TELEMETRY&.run_thread
  # A single worker reports: the metrics file store aggregates all workers.
  API_METRICS_REPORTER&.run_thread if index.zero?
end
after_stopped do
  CONNECTION_CHECKOUT_TELEMETRY&.shutdown!
  API_METRICS_REPORTER&.shutdown!
end
# simplecov:enable
