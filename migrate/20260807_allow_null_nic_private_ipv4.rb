# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:nic) do
      set_column_allow_null :private_ipv4
    end
    run "ALTER TABLE nic ADD CONSTRAINT nic_private_ipv4_presence_check CHECK (private_ipv4 IS NOT NULL OR state = 'creating') NOT VALID"
  end

  down do
    alter_table(:nic) do
      set_column_not_null :private_ipv4
    end
    run "ALTER TABLE nic DROP CONSTRAINT nic_private_ipv4_presence_check"
  end
end
