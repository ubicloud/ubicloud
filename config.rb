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
  mandatory :clover_column_encryption_key, base64, clear: true
  mandatory :clover_session_secret, base64, clear: true
  mandatory :rack_env, string

  # Optional -- value is returned or `nil` if it wasn't present.
  optional :clover_runtime_token_secret, base64, clear: true
  optional :heartbeat_url, string
  optional :clover_database_root_certs, string
  override :max_health_monitor_threads, 32, int
  override :max_metrics_export_threads, 32, int
  optional :omniauth_github_id, string, clear: true
  optional :omniauth_github_secret, string, clear: true
  optional :omniauth_google_id, string, clear: true
  optional :omniauth_google_secret, string, clear: true
  optional :hetzner_ssh_private_key, string, clear: true
  optional :hetzner_ssh_private_key_passphrase, string, clear: true
  optional :operator_ssh_public_keys, string

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
  override :db_pool_monitor, Config.db_pool, int
  override :dispatcher_max_threads, 8, int
  override :dispatcher_min_threads, 1, int
  override :dispatcher_queue_size_ratio, 4, float
  override :recursive_tag_limit, 32, int
  override :root, File.expand_path(__dir__), string
  optional :hetzner_user, string, clear: true
  optional :hetzner_password, string, clear: true
  override :hetzner_connection_string, "https://robot-ws.your-server.de", string
  override :managed_service, false, bool
  override :sanctioned_countries, "CU,IR,KP,SY", array(string)
  override :hetzner_ssh_public_key, string
  override :minimum_invoice_charge_threshold, 0.5, float
  optional :cloudflare_turnstile_site_key, string
  optional :cloudflare_turnstile_secret_key, string

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
  optional :github_runner_aws_location_id, string
  override :github_runner_aws_spot_instance_enabled, false, bool
  optional :github_runner_aws_spot_instance_max_price_per_vcpu, float

  # GitHub Cache
  optional :github_cache_blob_storage_endpoint, string
  optional :github_cache_blob_storage_region, string
  optional :github_cache_blob_storage_access_key, string, clear: true
  optional :github_cache_blob_storage_secret_key, string, clear: true
  optional :github_cache_blob_storage_account_id, string
  optional :github_cache_blob_storage_api_key, string, clear: true
  override :github_cache_blob_storage_use_account_token, false, bool

  # Minio
  override :minio_host_name, "minio.ubicloud.com", string
  optional :minio_service_project_id, string
  override :minio_version, "minio_20250723155402.0.0_amd64"

  # VictoriaMetrics
  optional :victoria_metrics_service_project_id, string
  override :victoria_metrics_host_name, "metrics.ubicloud.com", string
  override :victoria_metrics_version, "v1.113.0"

  # Spdk
  override :spdk_version, "v23.09-ubi-0.3"

  # Vhost Block Backend
  override :vhost_block_backend_version, "v0.2.0"

  # Boot Images
  override :default_boot_image_name, "ubuntu-jammy", string

  # Pagerduty
  optional :pagerduty_key, string, clear: true
  optional :pagerduty_log_link, string

  # Postgres
  optional :postgres_service_project_id, string
  override :postgres_service_hostname, "postgres.ubicloud.com", string
  override :postgres_monitor_database_url, Config.clover_database_url, string
  optional :postgres_monitor_database_root_certs, string
  optional :postgres_paradedb_notification_email, string
  optional :postgres_lantern_notification_email, string

  # Logging
  optional :database_logger_level, string

  # Ubicloud Images (Minio)
  override :ubicloud_images_bucket_name, "ubicloud-images", string
  optional :ubicloud_images_blob_storage_endpoint, string
  optional :ubicloud_images_blob_storage_access_key, string, clear: true
  optional :ubicloud_images_blob_storage_secret_key, string, clear: true
  optional :ubicloud_images_blob_storage_certs, string

  # Ubicloud Images (R2)
  optional :ubicloud_images_r2_bucket_name, string
  optional :ubicloud_images_r2_endpoint, string
  optional :ubicloud_images_r2_access_key, string, clear: true
  optional :ubicloud_images_r2_secret_key, string, clear: true

  override :ubuntu_noble_version, "20250502.1", string
  override :ubuntu_jammy_version, "20250508", string
  override :debian_12_version, "20250428-2096", string
  override :almalinux_9_version, "9.6-20250522", string
  override :github_ubuntu_2404_version, "20250821.1.0", string
  override :github_ubuntu_2204_version, "20250821.1.0", string
  override :github_gpu_ubuntu_2204_version, "20250821.1.0", string
  override :github_ubuntu_2204_aws_ami_version, "ami-04b5534ef1aed6bde", string
  override :github_ubuntu_2404_aws_ami_version, "ami-0908b850ff3e635a2", string
  override :postgres16_ubuntu_2204_version, "20250425.1.1", string
  override :postgres17_ubuntu_2204_version, "20250425.1.1", string
  override :postgres16_paradedb_ubuntu_2204_version, "20250901.1.0", string
  override :postgres17_paradedb_ubuntu_2204_version, "20250901.1.0", string
  override :postgres16_lantern_ubuntu_2204_version, "20250103.1.0", string
  override :postgres17_lantern_ubuntu_2204_version, "20250103.1.0", string
  override :ai_ubuntu_2404_nvidia_version, "20250505.1.0", string
  override :kubernetes_v1_32_version, "20250320.1.0", string
  override :kubernetes_v1_33_version, "20250506.1.0", string
  override :kubernetes_v1_34_version, "20250828.1.0", string

  override :aws_based_postgres_16_ubuntu_2204_ami_version, "ami-0c15093fa829f190a", string
  override :aws_based_postgres_17_ubuntu_2204_ami_version, "ami-0c8f8ddefeb7bd695", string

  # Allocator
  override :allocator_target_host_utilization, 0.72, float
  override :allocator_target_premium_host_utilization, 0.85, float
  override :allocator_max_random_score, 0.1, float

  # e2e
  override :e2e_hetzner_server_id, string
  optional :e2e_github_installation_id, string
  override :is_e2e, false, bool

  # Load Balancer
  optional :load_balancer_service_project_id, string
  optional :load_balancer_service_hostname, string

  # ACME
  # The following are optional because they are only needed in production.
  # They are not needed in development or test.
  optional :acme_email, string
  override :acme_directory, "https://acme.zerossl.com/v2/DV90", string
  optional :acme_eab_kid, string, clear: true
  optional :acme_eab_hmac_key, string, clear: true

  # AI
  optional :inference_endpoint_service_project_id, string
  optional :runpod_api_key, string, clear: true
  optional :huggingface_token, string, clear: true
  override :inference_dns_zone, "ai.ubicloud.com", string
  optional :inference_router_access_token, string, clear: true
  override :inference_router_release_tag, "v0.1.0", string

  # DNS
  optional :dns_service_project_id, string

  # Kubernetes
  optional :kubernetes_service_project_id, string
  optional :kubernetes_service_hostname, string

  # Billing
  optional :stripe_secret_key, string, clear: true
  override :annual_non_dutch_eu_sales_exceed_threshold, false, bool
  optional :invalid_vat_notification_email, string
  override :invoices_bucket_name, "ubicloud-invoices", string
  optional :invoices_blob_storage_endpoint, string
  optional :invoices_blob_storage_access_key, string, clear: true
  optional :invoices_blob_storage_secret_key, string, clear: true

  # Monitoring
  optional :monitoring_service_project_id, string
end
