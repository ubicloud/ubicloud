# frozen_string_literal: true

require_relative "../../model"

class PostgresMetricDestination < Sequel::Model
  many_to_one :postgres_resource, key: :postgres_resource_id

  plugin ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :password
  end
end

# Table: postgres_metric_destination
# Columns:
#  id                   | uuid | PRIMARY KEY
#  postgres_resource_id | uuid | NOT NULL
#  url                  | text | NOT NULL
#  username             | text | NOT NULL
#  password             | text | NOT NULL
# Indexes:
#  postgres_metric_destination_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_metric_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
