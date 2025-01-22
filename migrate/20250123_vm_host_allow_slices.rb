# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :accepts_slices, :boolean, null: false, default: false
    end
  end
end
