# frozen_string_literal: true

require_relative "../../model"

class PostgresLogDestination < Sequel::Model
  plugin ResourceMethods, encrypted_columns: {options: {format: :json}}
end

# Table: postgres_log_destination
# Columns:
#  id                   | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(45)
#  postgres_resource_id | uuid | NOT NULL
#  name                 | text | NOT NULL
#  type                 | text | NOT NULL
#  url                  | text | NOT NULL
#  options              | text |
# Indexes:
#  postgres_log_destination_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  valid_type | (type = ANY (ARRAY['otlp'::text, 'syslog'::text]))
# Foreign key constraints:
#  postgres_log_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
