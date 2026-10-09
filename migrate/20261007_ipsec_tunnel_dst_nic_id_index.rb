# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:ipsec_tunnel) do
      add_index :dst_nic_id, concurrently: true
    end
  end
end
