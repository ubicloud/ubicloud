# frozen_string_literal: true

require_relative "../model"

class ActionType < Sequel::Model
  plugin :static_cache
end

# Table: action_type
# Columns:
#  id   | uuid | PRIMARY KEY
#  name | text | NOT NULL
# Indexes:
#  action_type_pkey     | PRIMARY KEY btree (id)
#  action_type_name_key | UNIQUE btree (name)
