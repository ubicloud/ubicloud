# frozen_string_literal: true

module PostgresTestHelpers
  def create_postgres_timeline(location_id:)
    t = PostgresTimeline.create(location_id:, access_key: "dummy-access-key", secret_key: "dummy-secret-key")
    Strand.create_with_id(t, prog: "Postgres::PostgresTimelineNexus", label: "start")
    t
  end

  def create_postgres_resource(project:, location_id:)
    pg = PostgresResource.create(
      location_id:,
      project:,
      name: "pg-test-#{SecureRandom.hex(4)}",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      target_version: PostgresResource::DEFAULT_VERSION,
      flavor: "standard",
      ha_type: "none",
      parent_id: nil,
      restore_target: nil,
      user_config: {},
      pgbouncer_user_config: {},
      superuser_password: "dummy-password",
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2",
      server_cert: "server_cert",
      server_cert_key: "server_cert_key"
    )
    Strand.create_with_id(pg, prog: "Postgres::PostgresResourceNexus", label: "start")
    pg
  end
end

RSpec.configure do |config|
  config.include PostgresTestHelpers
end
