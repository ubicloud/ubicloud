# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    add_index :nic, [:private_subnet_id, :private_ipv4], name: :nic_private_subnet_id_private_ipv4_uidx, unique: true, concurrently: true

    alter_table(:nic) do
      set_column_allow_null :private_ipv4
    end
  end

  down do
    alter_table(:nic) do
      set_column_not_null :private_ipv4
    end

    drop_index :nic, [:private_subnet_id, :private_ipv4], name: :nic_private_subnet_id_private_ipv4_uidx, unique: true, concurrently: true
  end
end
