# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :vcpus, :integer, null: true
      add_column :memory_gib, :integer, null: true
    end
  end
end
