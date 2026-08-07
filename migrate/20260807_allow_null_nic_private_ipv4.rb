# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:nic) do
      set_column_allow_null :private_ipv4
    end
  end

  down do
    unless from(:nic).where(private_ipv4: nil).empty?
      raise "Cannot require NIC private IPv4 addresses while pending NICs have no address"
    end

    alter_table(:nic) do
      set_column_not_null :private_ipv4
    end
  end
end
