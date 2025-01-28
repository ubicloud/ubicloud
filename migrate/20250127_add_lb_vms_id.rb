# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:load_balancers_vms) do
      add_column :id, :uuid, null: true
    end
  end
end
