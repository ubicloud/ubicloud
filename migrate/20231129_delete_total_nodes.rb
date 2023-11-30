# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      drop_column :total_nodes
    end
  end
end
