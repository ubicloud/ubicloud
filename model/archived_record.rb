# frozen_string_literal: true

require_relative "../model"

class ArchivedRecord < Sequel::Model
  no_primary_key
end

# Table: archived_record
# Columns:
#  archived_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  model_name   | text                     | NOT NULL
#  model_values | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
# Indexes:
#  archived_record_model_name_archived_at_index | btree (model_name, archived_at)
