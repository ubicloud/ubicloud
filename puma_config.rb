# frozen_string_literal: true

# :nocov:
environment ENV["RACK_ENV"] || "development"
port ENV["PORT"] || "3000"
threads 5, 5

if @config.options[:workers] > 0
  silence_single_worker_warning
  preload_app!

  before_fork do
    Sequel::DATABASES.each(&:disconnect)
  end
end
# :nocov:
