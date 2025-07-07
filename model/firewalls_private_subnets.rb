# frozen_string_literal: true

require_relative "../model"

class FirewallsPrivateSubnets < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: firewalls_private_subnets
# Primary Key: (private_subnet_id, firewall_id)
# Columns:
#  private_subnet_id | uuid |
#  firewall_id       | uuid |
# Indexes:
#  firewalls_private_subnets_pkey | PRIMARY KEY btree (private_subnet_id, firewall_id)
# Foreign key constraints:
#  firewalls_private_subnets_firewall_id_fkey       | (firewall_id) REFERENCES firewall(id)
#  firewalls_private_subnets_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
