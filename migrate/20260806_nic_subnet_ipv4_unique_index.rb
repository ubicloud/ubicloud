# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    add_index :nic, [:private_subnet_id, :private_ipv4], name: :nic_private_subnet_id_private_ipv4_uidx, unique: true, concurrently: true
  end

  down do
    drop_index :nic, [:private_subnet_id, :private_ipv4], name: :nic_private_subnet_id_private_ipv4_uidx, unique: true, concurrently: true
  end
end
