# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :in_pool, type: :boolean, null: false, default: false
    end
  end
end
