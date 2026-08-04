# frozen_string_literal: true

require_relative "../model"

class VmHostInventory < Sequel::Model
  plugin :timestamps
end

# Table: vm_host_inventory
# Columns:
#  id            | uuid                     | PRIMARY KEY
#  updated_at    | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  server_model  | text                     |
#  cpu           | text                     |
#  memory        | text                     |
#  storage       | text                     |
#  uplink        | text                     |
#  gpu           | text                     |
#  monthly_price | numeric                  |
#  currency      | text                     |
# Indexes:
#  vm_host_inventory_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  allowed_currency           | (currency = ANY (ARRAY['EUR'::text, 'USD'::text]))
#  currency_with_price        | ((monthly_price IS NULL) = (currency IS NULL))
#  monthly_price_not_negative | (monthly_price >= 0::numeric)
# Foreign key constraints:
#  vm_host_inventory_id_fkey | (id) REFERENCES vm_host(id) ON DELETE CASCADE
