# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_pool) do
      add_column :arch, :arch, default: "x64", null: false
    end
  end
end
