# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      set_column_type(:mac, "macaddr USING mac::macaddr")
    end
  end
end
