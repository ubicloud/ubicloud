# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic) do
      add_column :state, :text
      add_constraint :state, "state IN ('initializing', 'creating', 'active')"
    end
  end
end
