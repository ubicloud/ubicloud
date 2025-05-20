# frozen_string_literal: true

require_relative "../../model"

class PostgresFirewallRule < Sequel::Model
  many_to_one :postgres_resource, key: :postgres_resource_id

  plugin ResourceMethods
end

# Table: postgres_firewall_rule
# Columns:
#  id                   | uuid | PRIMARY KEY
#  cidr                 | cidr | NOT NULL
#  postgres_resource_id | uuid | NOT NULL
#  description          | text |
# Indexes:
#  postgres_firewall_rule_pkey                          | PRIMARY KEY btree (id)
#  postgres_firewall_rule_postgres_resource_id_cidr_key | UNIQUE btree (postgres_resource_id, cidr)
# Foreign key constraints:
#  postgres_firewall_rule_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
