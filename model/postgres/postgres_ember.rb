# frozen_string_literal: true

require_relative "../../model"

# The Postgres side of an ember: a PostgreSQL database in its own micro-VM,
# obtainable in well under a second and costing nothing while paused.
#
# Everything about being a micro-VM in a slot -- placement, the volume, the
# pause and resume lifecycle -- belongs to Ember. What is here is what makes it
# a database rather than a generic ember: the version, the credentials, and the
# claim mechanics for a database somebody was handed before they had an
# account.
#
# It shares the ember's primary key, so a tenant sees one ubid for both.
class PostgresEmber < Sequel::Model
  many_to_one :ember, key: :id, is_used: true

  dataset_module Pagination

  plugin ResourceMethods, referencing: UBID::TYPE_EMBER, encrypted_columns: :superuser_password

  # How long an unclaimed ember survives without being claimed.
  DEFAULT_TTL = 72 * 60 * 60

  # Generic ember behaviour, answered on behalf of the row below. A
  # PostgresEmber is an Ember; making callers reach through would say otherwise
  # in every route, serializer and view on the Postgres surface.
  def name = ember.name
  def location = ember.location
  def location_id = ember.location_id
  def project_id = ember.project_id
  def state = ember.state
  def generation = ember.generation
  def slot = ember.slot
  def ip6 = ember.ip6
  def memory_mib = ember.memory_mib
  def cpu_percent_limit = ember.cpu_percent_limit
  def idle_timeout_seconds = ember.idle_timeout_seconds
  def last_activity_at = ember.last_activity_at
  def last_started_at = ember.last_started_at
  def last_paused_at = ember.last_paused_at
  def expires_at = ember.expires_at
  def protected = ember.protected
  def created_at = ember.created_at
  def detachable_volume = ember.detachable_volume
  def vm_host = ember.vm_host
  def vm_host_id = ember.vm_host_id
  def ember_template = ember.ember_template
  def ember_template_id = ember.ember_template_id
  def strand = ember.strand

  def semaphores = ember.semaphores

  def checkup_set?(...) = ember.checkup_set?(...)
  def running? = ember.running?
  def paused? = ember.paused?
  def expired? = ember.expired?
  def idle? = ember.idle?
  def display_state = ember.display_state
  def display_color = ember.display_color
  def incr_destroy = ember.incr_destroy
  def incr_pause = ember.incr_pause
  def incr_resume = ember.incr_resume
  def incr_checkup = ember.incr_checkup
  def destroy_set? = ember.destroy_set?
  def pause_set? = ember.pause_set?

  def hostname(suffix) = ember.hostname(suffix)

  def self.default_volume_size_gib = Config.postgres_ember_volume_size_gib

  def self.default_cpu_percent_limit = Config.postgres_ember_default_cpu_percent_limit

  def self.default_idle_timeout_seconds = Config.postgres_ember_idle_timeout_seconds

  def self.blank_guest_config = {"superuser_password" => SecureRandom.urlsafe_base64(24)}

  # Only hosts the gateways can reach: their end of the IPsec mesh is in place.
  def self.placeable_hosts(hosts)
    hosts.where(Sequel[:vm_host][:id] => PostgresGatewayHost.ready.select(:id))
  end

  def guest_config
    {"superuser_password" => superuser_password, "database" => database_name}
  end

  def claimed? = !claimed_at.nil?

  def path
    "/postgres-ember/#{ubid}"
  end

  # The gateway's IP address and port, where a deployment has no wildcard DNS
  # to find it by: a self-hosted one, or a development environment. Nil
  # otherwise.
  def self.gateway_address
    return unless (address = Config.postgres_gateway_address)
    host, _, port = address.rpartition(":")
    host.empty? ? [address, 5432] : [host, port.to_i]
  end

  # The ember id is the first label of the name, and the gateway reads it from
  # SNI; there is no other way to name an ember to it. Without wildcard DNS the
  # string also carries the gateway's address as hostaddr, so libpq dials
  # that and still sends the name.
  def connection_string(suffix)
    hostaddr, port = self.class.gateway_address
    URI::Generic.build(
      scheme: "postgres",
      userinfo: "postgres:#{URI.encode_uri_component(superuser_password)}",
      host: hostname(suffix),
      port: port || 5432,
      path: "/#{database_name}",
      query: hostaddr ? "sslmode=require&hostaddr=#{hostaddr}" : "sslmode=require",
    ).to_s
  end

  # Whether a claim token matches. Tokens are single use and stored hashed, so
  # a database leak does not hand over every unclaimed ember.
  def claim_token_matches?(token)
    return false if claim_token_digest.nil? || token.nil?
    OpenSSL.secure_compare(claim_token_digest, self.class.hash_claim_token(token))
  end

  def self.hash_claim_token(token)
    Digest::SHA256.hexdigest(token)
  end
end

# Table: postgres_ember
# Columns:
#  id                 | uuid                     | PRIMARY KEY
#  pg_version         | text                     | NOT NULL DEFAULT '18'::text
#  superuser_password | text                     | NOT NULL
#  database_name      | text                     | NOT NULL DEFAULT 'postgres'::text
#  claim_token_digest | text                     |
#  claimed_at         | timestamp with time zone |
#  creator_ip         | inet                     |
# Indexes:
#  postgres_ember_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_ember_id_fkey | (id) REFERENCES ember(id) ON DELETE CASCADE
