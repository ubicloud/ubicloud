# frozen_string_literal: true

require_relative "../model"

class ActionType < Sequel::Model
  plugin ResourceMethods

  plugin :static_cache

  NAME_MAP = Hash.new { |h, k| raise KeyError, "Invalid action type name: #{k}" }
  each { |t| NAME_MAP[t.name] = t.id }
  NAME_MAP.freeze
end

# Table: action_type
# Columns:
#  id   | uuid | PRIMARY KEY
#  name | text | NOT NULL
# Indexes:
#  action_type_pkey     | PRIMARY KEY btree (id)
#  action_type_name_key | UNIQUE btree (name)
