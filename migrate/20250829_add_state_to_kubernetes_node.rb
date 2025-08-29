# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_node) do
      add_column :state, :text, null: false, default: "active"
    end
  end
end
