# frozen_string_literal: true

require_relative "db"
require "sequel/model"

if ENV["RACK_ENV"] == "development"
  Sequel::Model.cache_associations = false
end

Sequel::Model.plugin :auto_validations, skip_invalid: true
Sequel::Model.plugin :require_valid_schema
Sequel::Model.plugin :singular_table_names
Sequel::Model.plugin :subclasses unless ENV["RACK_ENV"] == "development"
Sequel::Model.plugin :column_encryption do |enc|
  key = Config.clover_column_encryption_key
  if Config.kms_decrypt_clover_column_encryption_key_with_arn
    require "aws-sdk-kms"
    kms_client = Aws::KMS::Client.new
    ciphertext_blob = Base64.decode64(key)
    response = kms_client.decrypt(ciphertext_blob:, key_id: Config.kms_decrypt_clover_column_encryption_key_with_arn)
    key = response.plaintext
  end
  enc.key 0, key
end
Sequel::Model.plugin :many_through_many
Sequel::Model.plugin :insert_conflict
Sequel::Model.plugin :inspect_pk
Sequel::Model.plugin :static_cache_cache, "cache/static_cache.cache"
Sequel::Model.plugin :pg_auto_constraint_validations, cache_file: "cache/pg_auto_constraint_validations.cache"
Sequel::Model.plugin :pg_auto_validate_enums, message: proc { |valid_values| "is not one of the supported values (#{valid_values.sort.join(", ")})" }
Sequel::Model.plugin :pg_eager_any_typed_array
Sequel::Model.plugin :association_lazy_eager_option
Sequel::Model.plugin :forbid_lazy_load if Config.test? && ENV["CLOVER_FREEZE"] != "1"

if (level = Config.database_logger_level) || Config.test?
  require "logger"
  LOGGER = Logger.new($stdout, level: level || "fatal")
  DB.loggers << LOGGER
end

if ENV["CHECK_LOGGED_SQL"]
  require "logger"
  File.unlink("sql.log") if File.file?("sql.log")
  f = File.open("sql.log", "ab")

  # Remove optimization that does not use parameterization
  def (Sequel::Model).reset_fast_pk_lookup_sql = nil

  # Hack to make specs pass that mock Time.now and depend
  # on certain number of Time.now calls
  time = Time.now
  def time.now
    self
  end
  Logger.const_set(:Time, time)

  sql_logger = Logger.new(f, level: :INFO)
  sql_logger.formatter = proc do |sev, _, _, msg|
    "#{sev} -- : #{msg}\0"
  end

  DB.loggers << sql_logger
end

module SequelExtensions
  def delete(force: false, &)
    # Do not error if this is a plain dataset that does not respond to destroy
    return super(&) unless respond_to?(:destroy)

    caller_lines = caller
    rodauth_in_callstack = !caller_lines.grep(/rodauth/).empty?
    destroy_in_callstack = !caller_lines.grep(/sequel\/model\/base.*_destroy_delete/).empty?

    # This can happen when fast instance deletes are disabled (when CHECK_LOGGED_SQL
    # environment variable is set)
    callee_in_callstack = !caller_lines.grep(/#{Regexp.escape(__FILE__)}.*delete/).empty?

    unless rodauth_in_callstack || destroy_in_callstack || callee_in_callstack || force
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
