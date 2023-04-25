# frozen_string_literal: true

require_relative "db"
require "sequel/model"

if ENV["RACK_ENV"] == "development"
  Sequel::Model.cache_associations = false
end

Sequel::Model.plugin :auto_validations
Sequel::Model.plugin :require_valid_schema
Sequel::Model.plugin :singular_table_names
Sequel::Model.plugin :subclasses unless ENV["RACK_ENV"] == "development"
Sequel::Model.plugin :column_encryption do |enc|
  enc.key 0, Config.clover_column_encryption_key
end

module SemaphoreMethods
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def semaphore(*names)
      names.map!(&:intern)
      names.each do |name|
        define_method "incr_#{name}" do
          Semaphore.incr(id, name)
        end
      end
    end
  end
end

if ENV["RACK_ENV"] == "development"
  unless defined?(Unreloader)
    require "rack/unreloader"
    Unreloader = Rack::Unreloader.new(reload: false)
  end

  Unreloader.require("model") { |f| Sequel::Model.send(:camelize, File.basename(f).delete_suffix(".rb")) }
end

if ENV["RACK_ENV"] == "development" || ENV["RACK_ENV"] == "test"
  require "logger"
  LOGGER = Logger.new($stdout)
  LOGGER.level = Logger::FATAL if ENV["RACK_ENV"] == "test"
  DB.loggers << LOGGER
end
