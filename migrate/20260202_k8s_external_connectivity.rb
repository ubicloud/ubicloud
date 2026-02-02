# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_cluster) do
      add_column :connectivity_check_target, :text, null: true
    end
  end
end
