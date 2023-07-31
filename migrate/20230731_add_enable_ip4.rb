# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :ip4_enabled, TrueClass, default: false, null: false
    end
  end
end
