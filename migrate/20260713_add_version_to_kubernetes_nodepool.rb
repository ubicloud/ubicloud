# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_nodepool) do
      add_column :version, :text
    end
  end
end
