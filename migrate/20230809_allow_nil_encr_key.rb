# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      set_column_allow_null :encryption_key
    end
  end
end
