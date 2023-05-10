# frozen_string_literal: true

require_relative "loader"
# Adapted from
# https://github.com/interagent/pliny/blob/fcc8f3b103ec5296bd754898fdefeb2fda2ab292/lib/template/config/config.rb.
#
# It is MIT licensed.

# Access all config keys like the following:
#
#     Config.database_url
#
# Each accessor corresponds directly to an ENV key, which has the same name
# except upcased, i.e. `DATABASE_URL`.
module Config
  extend CastingConfigHelpers

  # Mandatory -- exception is raised for these variables when missing.
  mandatory :clover_database_url, string, clear: true
  mandatory :rack_env, string

  # Optional -- value is returned or `nil` if it wasn't present.
  optional :app_name, string
  optional :versioning_default, string
  optional :versioning_app_name, string
  optional :clover_session_secret, base64, clear: true
  optional :clover_column_encryption_key, base64, clear: true

  # Some email services use a secret token for both user and password,
  # so clear them both.
  optional :smtp_user, string, clear: true
  optional :smtp_password, string, clear: true
  optional :smtp_hostname, string

  optional :rodauth_email_from, string

  # Override -- value is returned or the set default.
  override :database_timeout, 10, int
  override :db_pool, 5, int
  override :deployment, "production", string
  override :force_ssl, true, bool
  override :app_env, "production", string
  override :port, 3000, int
  override :pretty_json, false, bool
  override :puma_max_threads, 16, int
  override :puma_min_threads, 1, int
  override :puma_workers, 3, int
  override :raise_errors, false, bool
  override :root, File.expand_path(__dir__), string
  override :timeout, 10, int
  override :versioning, false, bool
  override :minio_host_name, "storage.ubicloud.com", string

  def self.development?
    Config.rack_env == "development"
  end

  def self.test?
    Config.rack_env == "test"
  end
end
