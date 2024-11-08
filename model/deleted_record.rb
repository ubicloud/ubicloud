# frozen_string_literal: true

require_relative "../model"

class DeletedRecord < Sequel::Model
end

# Table: deleted_record
# Columns:
#  id           | uuid                     | PRIMARY KEY DEFAULT gen_random_uuid()
#  deleted_at   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  model_name   | text                     | NOT NULL
#  model_values | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
# Indexes:
#  deleted_record_pkey | PRIMARY KEY btree (id)
