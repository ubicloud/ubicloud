# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      set_column_not_null :state
    end
  end
end
