# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:nic) do
      drop_index nil, name: :nic_private_subnet_id_private_ipv4_uidx, concurrently: true, if_exists: true
    end

    duplicates = from(:nic)
      .exclude(private_ipv4: nil)
      .select_group(:private_subnet_id, :private_ipv4)
      .having(Sequel.function(:count).* > 1)
    unless duplicates.empty?
      raise "Cannot add the NIC private IPv4 unique index until duplicate addresses are repaired"
    end

    alter_table(:nic) do
      add_index [:private_subnet_id, :private_ipv4], unique: true, concurrently: true, name: :nic_private_subnet_id_private_ipv4_uidx
    end
  end

  down do
    alter_table(:nic) do
      drop_index nil, name: :nic_private_subnet_id_private_ipv4_uidx, concurrently: true, if_exists: true
    end
  end
end
