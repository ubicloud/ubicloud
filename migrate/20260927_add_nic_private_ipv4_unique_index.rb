# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :nic, [:private_subnet_id, :private_ipv4], unique: true, concurrently: true, name: :nic_private_subnet_id_private_ipv4_index
  end
end
