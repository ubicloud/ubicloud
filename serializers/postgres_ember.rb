# frozen_string_literal: true

class Serializers::PostgresEmber < Serializers::Base
  def self.serialize_internal(ember, options = {})
    base = {
      id: ember.ubid,
      name: ember.name,
      location: ember.location.display_name,
      state: ember.display_state,
      pg_version: ember.pg_version,
      database: ember.database_name,
      memory_mib: ember.memory_mib,
      idle_timeout_seconds: ember.idle_timeout_seconds,
      created_at: ember.created_at.iso8601,
      last_activity_at: ember.last_activity_at.iso8601,
    }
    base[:expires_at] = ember.expires_at.iso8601 if ember.expires_at

    # The password is only handed back when the caller asked for credentials,
    # so listing embers does not spray them through logs and caches.
    if options[:include_credentials]
      suffix = Config.postgres_gateway_hostname_suffix
      base.merge!(
        host: ember.hostname(suffix),
        port: PostgresEmber.gateway_address&.last || 5432,
        user: "postgres",
        password: ember.superuser_password,
        connection_string: ember.connection_string(suffix),
      )
    end
    base
  end
end
