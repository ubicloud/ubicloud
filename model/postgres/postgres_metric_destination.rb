# frozen_string_literal: true

require_relative "../../model"

class PostgresMetricDestination < Sequel::Model
  many_to_one :postgres_resource

  plugin ResourceMethods, encrypted_columns: {password: {}, options: {format: :json}}

  # Prometheus remote_write auth sections this destination configures.
  def auth_methods
    auth = username ? ["basic_auth"] : []
    auth.concat(%w[authorization headers] & options.keys) if options
    auth
  end
end

# Table: postgres_metric_destination
# Columns:
#  id                   | uuid | PRIMARY KEY
#  postgres_resource_id | uuid | NOT NULL
#  url                  | text | NOT NULL
#  username             | text |
#  password             | text |
#  options              | text |
# Indexes:
#  postgres_metric_destination_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_metric_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
