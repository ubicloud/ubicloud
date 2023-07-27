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
  def self.included(base)
    base.extend(ClassMethods)
  end

  def ubid
    @ubid ||= UBID.from_uuidish(id).to_s.downcase
  end

  NON_ARCHIVED_MODELS = ["DeletedRecord", "Semaphore"]
  def before_destroy
    model_name = self.class.name
    unless NON_ARCHIVED_MODELS.include?(model_name)
      model_values = values.merge(model_name: model_name)

      DeletedRecord.create(deleted_at: Time.now, model_name: model_name, model_values: model_values)
    end

    super
  end

  module ClassMethods
    # Adapted from sequel/model/inflections.rb's underscore, to convert
    # class names into symbols
    def self.uppercase_underscore(s)
      s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-", "_").upcase
    end

    def from_ubid(ubid)
      self[id: UBID.parse(ubid).to_uuid]
    rescue UBIDParseError
      nil
    end

    def ubid_type
      Object.const_get("UBID::TYPE_#{ClassMethods.uppercase_underscore(name)}")
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
