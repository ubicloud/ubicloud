# frozen_string_literal: true

require_relative "loader"
# Migrate

migrate = lambda do |env, version|
  ENV["RACK_ENV"] = env
  require_relative "db"
  require "logger"
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

# Specs

spec = proc do |type|
  desc "Run #{type} specs"
  task :"#{type}_spec" do
    sh "rspec spec/#{type}"
  end

  desc "Run #{type} specs with coverage"
  task :"#{type}_spec_cov" do
    ENV["COVERAGE"] = type
    sh "rspec spec/#{type}"
    ENV.delete("COVERAGE")
  end
end
spec.call("model")
spec.call("web")

desc "Run all specs"
task default: [:model_spec, :web_spec]

desc "Run all specs with coverage"
task spec_cov: [:model_spec_cov, :web_spec_cov]

# Other

desc "Annotate Sequel models"
task "annotate" do
  ENV["RACK_ENV"] = "development"
  require_relative "model"
  DB.loggers.clear
  require "sequel/annotate"
  Sequel::Annotate.annotate(Dir["model/**/*.rb"])
end
