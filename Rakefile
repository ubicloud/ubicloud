# frozen_string_literal: true

# Migrate

migrate = lambda do |env, version|
  ENV["RACK_ENV"] = env
  require_relative "loader"
  require "logger"
  require "sequel"
  Sequel.extension :migration
  DB.loggers << Logger.new($stdout) if DB.loggers.empty?
  Sequel::Migrator.apply(DB, "migrate", version)
end

desc "Migrate test database to latest version"
task :test_up do
  migrate.call("test", nil)
end

desc "Migrate test database all the way down"
task :test_down do
  migrate.call("test", 0)
end

desc "Migrate test database all the way down and then back up"
task :test_bounce do
  migrate.call("test", 0)
  Sequel::Migrator.apply(DB, "migrate")
end

desc "Migrate development database to latest version"
task :dev_up do
  migrate.call("development", nil)
end

desc "Migrate development database to all the way down"
task :dev_down do
  migrate.call("development", 0)
end

desc "Migrate development database all the way down and then back up"
task :dev_bounce do
  migrate.call("development", 0)
  Sequel::Migrator.apply(DB, "migrate")
end

desc "Migrate production database to latest version"
task :prod_up do
  migrate.call("production", nil)
end

desc "Generate a new .env.rb"
task :overwrite_envrb do
  require "securerandom"

  File.write(".env.rb", <<ENVRB)
case ENV["RACK_ENV"] ||= "development"
when "test"
  ENV["CLOVER_SESSION_SECRET"] ||= "#{SecureRandom.base64(64)}"
  ENV["CLOVER_DATABASE_URL"] ||= "postgres:///clover_test?user=clover"
  ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "#{SecureRandom.base64(32)}"
else
  ENV["CLOVER_SESSION_SECRET"] ||= "#{SecureRandom.base64(64)}"
  ENV["CLOVER_DATABASE_URL"] ||= "postgres:///clover_development?user=clover"
  ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "#{SecureRandom.base64(32)}"
end
ENVRB
end

# Specs
begin
  require "rspec/core/rake_task"
  ENV["RACK_ENV"] = "test"
  RSpec::Core::RakeTask.new(:spec)
  task default: :spec
rescue LoadError
end

# Other

desc "Annotate Sequel models"
task "annotate" do
  ENV["RACK_ENV"] = "development"
  require_relative "loader"
  require_relative "model"
  DB.loggers.clear
  require "sequel/annotate"
  Sequel::Annotate.annotate(Dir["model/**/*.rb"])
end
