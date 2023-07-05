# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :total_hugepages_1g, :Integer, null: false, default: 0
      add_column :used_hugepages_1g, :Integer, null: false, default: 0
    end
  end
end
