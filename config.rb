# frozen_string_literal: true

require_relative "lib/casting_config_helpers"

begin
  require_relative ".env"
rescue LoadError
  # .env.rb is optional
end

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

  def self.production?
    Config.rack_env == "production"
  end

  def self.development?
    Config.rack_env == "development"
  end

  def self.test?
    Config.rack_env == "test"
  end

  # Mandatory -- exception is raised for these variables when missing.
  mandatory :clover_database_url, string, clear: true
  mandatory :rack_env, string

  # Optional -- value is returned or `nil` if it wasn't present.
  optional :app_name, string
  optional :versioning_default, string
  optional :versioning_app_name, string
  optional :clover_session_secret, base64, clear: true
  optional :clover_column_encryption_key, base64, clear: true
  optional :stripe_public_key, string, clear: true
  optional :stripe_secret_key, string, clear: true
  optional :heartbeat_url, string
  optional :clover_database_root_certs, string
  override :max_monitor_threads, 32, int

  # :nocov:
  override :mail_driver, (production? ? :smtp : :logger), symbol
  override :mail_from, (production? ? nil : "dev@example.com"), string
  # :nocov:
  # Some email services use a secret token for both user and password,
  # so clear them both.
  optional :smtp_user, string, clear: true
  optional :smtp_password, string, clear: true
  optional :smtp_hostname, string
  override :smtp_port, 587, int
  override :smtp_tls, true, bool

  # Override -- value is returned or the set default.
  override :base_url, "http://localhost:9292", string
  override :database_timeout, 10, int
  override :db_pool, 5, int
  override :deployment, "production", string
  override :force_ssl, true, bool
  override :port, 3000, int
  override :pretty_json, false, bool
  override :puma_max_threads, 16, int
  override :puma_min_threads, 1, int
  override :puma_workers, 3, int
  override :raise_errors, false, bool
  override :root, File.expand_path(__dir__), string
  override :timeout, 10, int
  override :versioning, false, bool
  optional :hetzner_user, string, clear: true
  optional :hetzner_password, string, clear: true
  override :ci_hetzner_sacrificial_server_id, string
  override :hetzner_connection_string, "https://robot-ws.your-server.de", string
  override :managed_service, false, bool
  override :sanctioned_countries, "CU,IR,KP,SY", array(string)
  override :hetzner_ssh_key, string
  override :minimum_invoice_charge_threshold, 0.5, float

  # GitHub Runner App
  optional :github_app_name, string
  optional :github_app_id, string
  optional :github_app_client_id, string, clear: true
  optional :github_app_client_secret, string, clear: true
  optional :github_app_private_key, string, clear: true
  optional :github_app_webhook_secret, string, clear: true
  optional :vm_pool_project_id, string
  optional :github_runner_service_project_id, string
  override :enable_github_workflow_poller, true, bool

  # Minio
  override :minio_host_name, "minio.ubicloud.com", string
  optional :minio_service_project_id, string
  override :minio_version, "minio_20240406052602.0.0_amd64"

  # Spdk
  override :spdk_version, "v23.09-ubi-0.2"

  # Boot Images
  override :default_boot_image_name, "ubuntu-jammy", string

  # Pagerduty
  optional :pagerduty_key, string, clear: true
  optional :pagerduty_log_link, string

  # Postgres
  optional :postgres_service_project_id, string
  override :postgres_service_hostname, "postgres.ubicloud.com", string
  optional :postgres_service_blob_storage_access_key, string
  optional :postgres_service_blob_storage_secret_key, string, clear: true
  optional :postgres_service_blob_storage_id, string
  override :postgres_monitor_database_url, Config.clover_database_url, string
  optional :postgres_monitor_database_root_certs, string

  # Logging
  optional :database_logger_level, string

  # Ubicloud Images
  override :ubicloud_images_bucket_name, "ubicloud-images", string
  optional :ubicloud_images_blob_storage_endpoint, string
  optional :ubicloud_images_blob_storage_access_key, string, clear: true
  optional :ubicloud_images_blob_storage_secret_key, string, clear: true
  optional :ubicloud_images_blob_storage_certs, string

  override :ubuntu_jammy_version, "20240319", string
  override :github_ubuntu_2204_version, "20240422.1.0", string
  override :github_ubuntu_2004_version, "20240422.1.0", string
  override :postgres_ubuntu_2204_version, "20240226.1.0", string
  override :github_gpu_ubuntu_2204_version, "20240422.1.0", string

  # Allocator
  override :allocator_target_host_utilization, 0.55, float
  override :allocator_max_random_score, 0.1, float

  # e2e
  optional :e2e_github_installation_id, string
end
