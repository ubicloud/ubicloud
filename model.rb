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

module ResourceMethods
  require_relative "lib/ubid"

  def self.included(base)
    base.extend(ClassMethods)
  end

  def ubid
    @ubid ||= UBID.from_uuidish(id).to_s.downcase
  end

  module ClassMethods
    def from_ubid(ubid)
      self[id: UBID.parse(ubid).to_uuid]
    rescue UBIDParseError
      nil
    end

    def create_with_id(*args, **kwargs)
      create(*args, **kwargs) { _1.id = UBID.generate(ubid_type).to_uuid }
    end
  end
end

if ENV["RACK_ENV"] == "development" || ENV["RACK_ENV"] == "test"
  require "logger"
  LOGGER = Logger.new($stdout)
  LOGGER.level = Logger::FATAL if ENV["RACK_ENV"] == "test"
  DB.loggers << LOGGER
end
