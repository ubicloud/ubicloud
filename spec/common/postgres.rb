# frozen_string_literal: true

module PostgresTestHelpers
  def create_postgres_timeline(location_id:)
    t = PostgresTimeline.create(location_id:, access_key: "dummy-access-key", secret_key: "dummy-secret-key")
    Strand.create_with_id(t, prog: "Postgres::PostgresTimelineNexus", label: "start")
    t
  end
end

RSpec.configure do |config|
  config.include PostgresTestHelpers
end
