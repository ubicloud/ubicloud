# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :csum_guard_enabled, :boolean, null: false, default: false
    end
  end
end
