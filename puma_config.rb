# frozen_string_literal: true

# :nocov:
environment ENV["RACK_ENV"] || "development"
port ENV["PORT"] || "3000"
threads 15, 15
enable_keep_alives false

if @config.options[:workers] > 0
  silence_single_worker_warning
  preload_app!

  before_fork do
    Sequel::DATABASES.each(&:disconnect)
  end
end
# :nocov:
