require_relative 'db'
require 'sequel/model'

if ENV['RACK_ENV'] == 'development'
  Sequel::Model.cache_associations = false
end

Sequel::Model.plugin :auto_validations
Sequel::Model.plugin :prepared_statements
Sequel::Model.plugin :subclasses unless ENV['RACK_ENV'] == 'development'

unless defined?(Unreloader)
  require 'rack/unreloader'
  Unreloader = Rack::Unreloader.new(reload: false)
end

Unreloader.require('models'){|f| Sequel::Model.send(:camelize, File.basename(f).sub(/\.rb\z/, ''))}

if ENV['RACK_ENV'] == 'development' || ENV['RACK_ENV'] == 'test'
  require 'logger'
  LOGGER = Logger.new($stdout)
  LOGGER.level = Logger::FATAL if ENV['RACK_ENV'] == 'test'
  DB.loggers << LOGGER
end

unless ENV['RACK_ENV'] == 'development'
  Sequel::Model.freeze_descendents
  DB.freeze
end
