# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:spdk_installation) do
      add_column :cpu_count, :int, default: 2, null: false
    end
  end
end
