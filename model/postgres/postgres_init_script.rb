# frozen_string_literal: true

require_relative "../../model"

class PostgresInitScript < Sequel::Model
  plugin ResourceMethods, etc_type: true, encrypted_columns: :init_script

  def validate
    super
    validates_max_length(3000, :init_script)
  end
end

# Table: postgres_init_script
# Columns:
#  id          | uuid | PRIMARY KEY
#  init_script | text | NOT NULL
# Indexes:
#  postgres_init_script_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_init_script_id_fkey | (id) REFERENCES postgres_resource(id)
