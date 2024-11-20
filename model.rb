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
Sequel::Model.plugin :many_through_many
Sequel::Model.plugin :insert_conflict
Sequel::Model.plugin :inspect_pk

module SemaphoreMethods
  def self.included(base)
    base.class_eval do
      one_to_many :semaphores, key: :strand_id
    end
    base.extend(ClassMethods)
  end

  module ClassMethods
    def semaphore(*names)
      names.each do |sym|
        name = sym.name
        define_method :"incr_#{name}" do
          Semaphore.incr(id, sym)
        end

        define_method :"#{name}_set?" do
          semaphores.any? { |s| s.name == name }
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

  def to_s
    inspect_prefix
  end

  def inspect_pk
    ubid if id
  end

  INSPECT_CONVERTERS = {
    "uuid" => lambda { |v| UBID.from_uuidish(v).to_s },
    "cidr" => :to_s.to_proc,
    "inet" => :to_s.to_proc,
    "timestamp with time zone" => lambda { |v| v.strftime("%F %T") }
  }.freeze
  def inspect_values
    inspect_values = {}
    sch = db_schema
    @values.except(*self.class.redacted_columns).each do |k, v|
      next if k == :id

      inspect_values[k] = if v
        if (converter = INSPECT_CONVERTERS[sch[k][:db_type]])
          converter.call(v)
        else
          v
        end
      else
        v
      end
    end
    inspect_values.inspect
  end

  NON_ARCHIVED_MODELS = ["DeletedRecord", "Semaphore"]
  def before_destroy
    model_name = self.class.name
    unless NON_ARCHIVED_MODELS.include?(model_name)
      model_values = values.merge(model_name: model_name)

      encryption_metadata = self.class.instance_variable_get(:@column_encryption_metadata)
      unless encryption_metadata.empty?
        encryption_metadata.keys.each do |key|
          model_values.delete(key)
        end
      end

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

    def [](arg)
      if arg.is_a?(UBID)
        super(arg.to_uuid)
      elsif arg.is_a?(String) && arg.bytesize == 26
        begin
          ubid = UBID.parse(arg)
        rescue UBIDParseError
          super
        else
          super(ubid.to_uuid)
        end
      else
        super
      end
    end

    def from_ubid(ubid)
      self[id: UBID.parse(ubid).to_uuid]
    rescue UBIDParseError
      nil
    end

    def ubid_type
      Object.const_get("UBID::TYPE_#{ClassMethods.uppercase_underscore(name)}")
    end

    def generate_ubid
      UBID.generate(ubid_type)
    end

    def generate_uuid
      generate_ubid.to_uuid
    end

    def new_with_id(*, **)
      new(*, **) { _1.id = generate_uuid }
    end

    def create_with_id(*, **)
      create(*, **) { _1.id = generate_uuid }
    end

    def redacted_columns
      column_encryption_metadata.keys || []
    end
  end
end

module HealthMonitorMethods
  def aggregate_readings(previous_pulse:, reading:, data: {})
    {
      reading: reading,
      reading_rpt: (previous_pulse[:reading] == reading) ? previous_pulse[:reading_rpt] + 1 : 1,
      reading_chg: (previous_pulse[:reading] == reading) ? previous_pulse[:reading_chg] : Time.now
    }.merge(data)
  end

  def needs_event_loop_for_pulse_check?
    false
  end
end

if (level = Config.database_logger_level)
  require "logger"
  DB.loggers << Logger.new($stdout, level: level)
end

module SequelExtensions
  def delete(force: false, &)
    rodaauth_in_callstack = !caller.grep(/rodauth/).empty?
    destroy_in_callstack = !caller.grep(/sequel\/model\/base.*_destroy_delete/).empty?
    unless rodaauth_in_callstack || destroy_in_callstack || force
      raise "Calling delete is discouraged as it skips hooks such as before_destroy, which " \
            "we use to archive records. Use destroy instead. If you know what you are doing " \
            "and still want to use delete, you can pass force: true to trigger delete."
    end

    if is_a?(Sequel::Dataset)
      super(&)
    else
      super()
    end
  end
end

module Sequel
  class Dataset
    prepend SequelExtensions
  end

  class Model
    prepend SequelExtensions
  end
end
