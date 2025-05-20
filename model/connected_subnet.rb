# frozen_string_literal: true

require_relative "../model"

class ConnectedSubnet < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: connected_subnet
# Columns:
#  id          | uuid | PRIMARY KEY
#  subnet_id_1 | uuid | NOT NULL
#  subnet_id_2 | uuid | NOT NULL
# Indexes:
#  connected_subnet_pkey                        | PRIMARY KEY btree (id)
#  connected_subnet_subnet_id_1_subnet_id_2_key | UNIQUE btree (subnet_id_1, subnet_id_2)
#  connected_subnet_subnet_id_2_index           | btree (subnet_id_2)
# Check constraints:
#  unique_subnet_pair | (subnet_id_1 < subnet_id_2)
# Foreign key constraints:
#  connected_subnet_subnet_id_1_fkey | (subnet_id_1) REFERENCES private_subnet(id)
#  connected_subnet_subnet_id_2_fkey | (subnet_id_2) REFERENCES private_subnet(id)
